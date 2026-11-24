-- Mahjong Record v3: private rooms and safe, versioned match snapshots.
-- Execute in Supabase SQL editor on a NEW project after reviewing the schema.
-- Requires Supabase Auth and PostgreSQL 14+ (built-in SHA-256). No service_role credentials in browser.
-- Run the complete file in one transaction to avoid temporary RPC grants.
begin;

create table if not exists public.mahjong_rooms (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 100),
  created_at timestamptz not null default now()
);
create table if not exists public.mahjong_room_members (
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id,user_id)
);
create table if not exists public.mahjong_room_matches (
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  match_key text not null check (char_length(match_key) between 1 and 120),
  payload jsonb not null check (jsonb_typeof(payload)='object'),
  version integer not null default 1 check (version between 1 and 2147483647),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (room_id,match_key)
);
create table if not exists public.mahjong_room_match_history (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  match_key text not null,
  old_version integer,
  new_version integer not null,
  payload jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by uuid references auth.users(id) on delete set null
);
create table if not exists public.mahjong_room_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users(id) on delete set null,
  constraint valid_invite_expiration check(expires_at>created_at)
);
create index if not exists mahjong_rooms_owner_idx on public.mahjong_rooms(owner_id);
create index if not exists mahjong_members_user_idx on public.mahjong_room_members(user_id);
create index if not exists mahjong_invites_room_idx on public.mahjong_room_invites(room_id);
create index if not exists mahjong_history_match_idx on public.mahjong_room_match_history(room_id,match_key,new_version);

alter table public.mahjong_rooms enable row level security;
alter table public.mahjong_room_members enable row level security;
alter table public.mahjong_room_matches enable row level security;
alter table public.mahjong_room_match_history enable row level security;
alter table public.mahjong_room_invites enable row level security;

-- Deny all direct table mutations. All writes use audited security-definer RPCs.
revoke all on public.mahjong_rooms, public.mahjong_room_members,
 public.mahjong_room_matches, public.mahjong_room_match_history,
 public.mahjong_room_invites from anon, authenticated;
grant select on public.mahjong_rooms, public.mahjong_room_members,
 public.mahjong_room_matches to authenticated;
revoke all on public.mahjong_room_match_history, public.mahjong_room_invites from authenticated;

create or replace function public.mahjong_is_owner(p_room_id uuid)
returns boolean language sql stable security definer
set search_path = '' as $$
 select exists(select 1 from public.mahjong_rooms r
   where r.id=p_room_id and r.owner_id=(select auth.uid()));
$$;
create or replace function public.mahjong_can_view(p_room_id uuid)
returns boolean language sql stable security definer
set search_path = '' as $$
 select exists(select 1 from public.mahjong_rooms r
   where r.id=p_room_id and r.owner_id=(select auth.uid()))
 or exists(select 1 from public.mahjong_room_members m
   where m.room_id=p_room_id and m.user_id=(select auth.uid()));
$$;
revoke all on function public.mahjong_is_owner(uuid),public.mahjong_can_view(uuid) from public,anon;
grant execute on function public.mahjong_is_owner(uuid),public.mahjong_can_view(uuid) to authenticated;

drop policy if exists mahjong_room_read on public.mahjong_rooms;
create policy mahjong_room_read on public.mahjong_rooms for select to authenticated
using (public.mahjong_can_view(id));
drop policy if exists mahjong_member_read on public.mahjong_room_members;
create policy mahjong_member_read on public.mahjong_room_members for select to authenticated
using (user_id=(select auth.uid()) or public.mahjong_is_owner(room_id));
drop policy if exists mahjong_match_read on public.mahjong_room_matches;
create policy mahjong_match_read on public.mahjong_room_matches for select to authenticated
using (public.mahjong_can_view(room_id));

create or replace function public.mahjong_create_room(p_title text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_room uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_title is null or char_length(btrim(p_title)) not between 1 and 100 then
  raise exception 'Invalid room title';
 end if;
 insert into public.mahjong_rooms(owner_id,title)
 values(auth.uid(),btrim(p_title)) returning id into v_room;
 return v_room;
end;$$;

-- A one-time, 24-hour invitation. Token is returned once, never stored in plaintext.
create or replace function public.mahjong_create_invite(p_room_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
 if auth.uid() is null or not public.mahjong_is_owner(p_room_id) then
   raise exception 'Not room owner';
 end if;
 v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
 insert into public.mahjong_room_invites(room_id,token_hash,expires_at)
 values (p_room_id,encode(pg_catalog.sha256(convert_to(v_token,'UTF8')),'hex'),now()+interval '24 hours');
 return v_token;
end;$$;

create or replace function public.mahjong_accept_invite(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_room uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then raise exception 'Invalid invitation'; end if;
 -- UPDATE lock makes a single-use token safe under simultaneous requests.
 update public.mahjong_room_invites
 set used_at=now(),used_by=auth.uid()
 where token_hash=encode(pg_catalog.sha256(convert_to(p_token,'UTF8')),'hex')
 and used_at is null and expires_at>now()
 returning room_id into v_room;
 if v_room is null then raise exception 'Invitation expired or already used'; end if;
 insert into public.mahjong_room_members(room_id,user_id)
 values (v_room,auth.uid()) on conflict do nothing;
 return v_room;
end;$$;

-- Optimistic concurrency prevents lost updates.
-- p_expected_version is NULL only on first insertion.
create or replace function public.mahjong_save_match(
 p_room_id uuid,p_match_key text,p_payload jsonb,p_expected_version integer default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_version integer;
begin
 if auth.uid() is null or not public.mahjong_is_owner(p_room_id) then
  raise exception 'Not room owner';
 end if;
 if p_match_key is null or char_length(p_match_key) not between 1 and 120
    or p_payload is null or jsonb_typeof(p_payload)<>'object'
    or octet_length(p_payload::text)>500000 then raise exception 'Invalid match payload'; end if;
 if p_expected_version is null then
   insert into public.mahjong_room_matches(room_id,match_key,payload,version,updated_by)
   values (p_room_id,p_match_key,p_payload,1,auth.uid())
   on conflict do nothing returning version into v_version;
   if v_version is null then raise exception 'Version conflict: match already exists'; end if;
 else
   if p_expected_version<1 or p_expected_version>=2147483647 then
    raise exception 'Invalid version'; end if;
   update public.mahjong_room_matches
     set payload=p_payload,version=version+1,updated_at=now(),updated_by=auth.uid()
   where room_id=p_room_id and match_key=p_match_key and version=p_expected_version
   returning version into v_version;
   if v_version is null then raise exception 'Version conflict: refresh first'; end if;
 end if;
 insert into public.mahjong_room_match_history(room_id,match_key,old_version,new_version,payload,changed_by)
 values (p_room_id,p_match_key,p_expected_version,v_version,p_payload,auth.uid());
 return v_version;
end;$$;

revoke all on function public.mahjong_create_room(text),
 public.mahjong_create_invite(uuid),public.mahjong_accept_invite(text),
 public.mahjong_save_match(uuid,text,jsonb,integer) from public,anon;
grant execute on function public.mahjong_create_room(text),
 public.mahjong_create_invite(uuid),public.mahjong_accept_invite(text),
 public.mahjong_save_match(uuid,text,jsonb,integer) to authenticated;

-- For Supabase Realtime, add mahjong_room_matches to supabase_realtime publication
-- manually after RLS checks and the application's membership logic are tested.

commit;
