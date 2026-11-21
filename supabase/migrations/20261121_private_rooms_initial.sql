-- v3.0 development schema: apply only to a NEW, isolated Supabase project.
-- This is a development starting point, not a production deployment.
create extension if not exists pgcrypto;

create table if not exists public.mahjong_rooms (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null default '新しい半荘',
  match_date date not null default current_date,
  status text not null default 'active' check (status in ('active','finished','void')),
  created_at timestamptz not null default now()
);

create table if not exists public.mahjong_room_members (
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id,user_id)
);

create table if not exists public.mahjong_room_snapshots (
  room_id uuid primary key references public.mahjong_rooms(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  payload jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint snapshot_size_limit check (octet_length(payload::text) <= 1024 * 1024)
);

create index if not exists mahjong_rooms_owner_idx on public.mahjong_rooms(owner_id);
create index if not exists mahjong_members_user_idx on public.mahjong_room_members(user_id);

-- SECURITY DEFINER helpers avoid recursive RLS lookups between rooms and members.
-- Restrict their input to the current authenticated user; callers cannot check a different user.
create schema if not exists private;
create or replace function private.mahjong_is_owner(target_room uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.mahjong_rooms r
    where r.id=target_room and r.owner_id=(select auth.uid())
  );
$$;

create or replace function private.mahjong_is_member(target_room uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.mahjong_room_members m
    where m.room_id=target_room and m.user_id=(select auth.uid())
  );
$$;

revoke all on function private.mahjong_is_owner(uuid) from public;
revoke all on function private.mahjong_is_member(uuid) from public;
grant usage on schema private to authenticated;
grant execute on function private.mahjong_is_owner(uuid) to authenticated;
grant execute on function private.mahjong_is_member(uuid) to authenticated;

alter table public.mahjong_rooms enable row level security;
alter table public.mahjong_room_members enable row level security;
alter table public.mahjong_room_snapshots enable row level security;

revoke all on public.mahjong_rooms, public.mahjong_room_members, public.mahjong_room_snapshots from anon;
grant select, insert, update, delete on public.mahjong_rooms to authenticated;
grant select, insert, delete on public.mahjong_room_members to authenticated;
grant select, insert, update on public.mahjong_room_snapshots to authenticated;

create policy "rooms_read_owner_or_member"
on public.mahjong_rooms for select to authenticated
using (owner_id = (select auth.uid()) or (select private.mahjong_is_member(id)));

create policy "rooms_create_self"
on public.mahjong_rooms for insert to authenticated
with check (owner_id = (select auth.uid()));

create policy "rooms_owner_update"
on public.mahjong_rooms for update to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

create policy "rooms_owner_delete"
on public.mahjong_rooms for delete to authenticated
using (owner_id = (select auth.uid()));

create policy "members_read_self_or_owner"
on public.mahjong_room_members for select to authenticated
using (user_id = (select auth.uid()) or (select private.mahjong_is_owner(room_id)));

-- Owner can add viewers ONLY during development; replace with verified invite flow.
-- Do not expose a public client-side "join any room" endpoint.
create policy "members_owner_add"
on public.mahjong_room_members for insert to authenticated
with check ((select private.mahjong_is_owner(room_id)));

create policy "members_owner_remove"
on public.mahjong_room_members for delete to authenticated
using ((select private.mahjong_is_owner(room_id)));

create policy "snapshots_read_owner_or_member"
on public.mahjong_room_snapshots for select to authenticated
using ((select private.mahjong_is_owner(room_id)) or (select private.mahjong_is_member(room_id)));

create policy "snapshots_insert_owner"
on public.mahjong_room_snapshots for insert to authenticated
with check ((select private.mahjong_is_owner(room_id)) and updated_by=(select auth.uid()));

create policy "snapshots_update_owner"
on public.mahjong_room_snapshots for update to authenticated
using ((select private.mahjong_is_owner(room_id)))
with check ((select private.mahjong_is_owner(room_id)) and updated_by=(select auth.uid()));

-- DO NOT enable clients to update snapshots directly in production:
-- revision checking and idempotency must be added via an atomic RPC.
-- Realtime will be enabled only after RLS + subscription tests pass.
