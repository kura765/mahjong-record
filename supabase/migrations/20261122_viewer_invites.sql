-- v3.0 development ONLY: private, single-use invitation codes.
-- Run after both 20261121 migrations, against mahjong-dev only.
-- Important: invitation secrets are never selectable by normal app clients.
create table if not exists public.mahjong_room_invitations (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
  token_hash bytea not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users(id)
);
create index if not exists mahjong_invites_room_idx on public.mahjong_room_invitations(room_id);
alter table public.mahjong_room_invitations enable row level security;
revoke all on public.mahjong_room_invitations from public, anon, authenticated;

create or replace function public.mahjong_create_viewer_invite(p_room_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text;
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'ログインが必要です' using errcode='28000';
  end if;
  if not exists (select 1 from public.mahjong_rooms
      where id=p_room_id and owner_id=v_user) then
    raise exception '招待権限がありません' using errcode='42501';
  end if;
  -- At most five unredeemed, unexpired invitations per room.
  if (select count(*) from public.mahjong_room_invitations
      where room_id=p_room_id and redeemed_at is null and expires_at>now()) >= 5 then
    raise exception '未使用の招待コードは最大5件です' using errcode='22023';
  end if;
  v_code := replace(gen_random_uuid()::text,'-','') ||
            replace(gen_random_uuid()::text,'-','');
  insert into public.mahjong_room_invitations(room_id,token_hash,created_by,expires_at)
  values(p_room_id,pg_catalog.sha256(pg_catalog.convert_to(v_code,'UTF8')),v_user,now()+interval '48 hours');
  return v_code;
end;
$$;

create or replace function public.mahjong_accept_viewer_invite(p_code text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_inv public.mahjong_room_invitations%rowtype;
begin
  if v_user is null then
    raise exception 'ログインが必要です' using errcode='28000';
  end if;
  if p_code is null or p_code !~ '^[a-f0-9]{64}$' then
    raise exception '招待コードの形式が違います' using errcode='22023';
  end if;
  select * into v_inv from public.mahjong_room_invitations
  where token_hash=pg_catalog.sha256(pg_catalog.convert_to(p_code,'UTF8'))
    and redeemed_at is null and expires_at>now()
  for update;
  if not found then
    raise exception '招待コードは無効、使用済み、または期限切れです' using errcode='22023';
  end if;
  insert into public.mahjong_room_members(room_id,user_id)
  values(v_inv.room_id,v_user)
  on conflict (room_id,user_id) do nothing;
  update public.mahjong_room_invitations
  set redeemed_at=now(),redeemed_by=v_user
  where id=v_inv.id;
  return v_inv.room_id;
end;
$$;

revoke all on function public.mahjong_create_viewer_invite(uuid) from public, anon;
revoke all on function public.mahjong_accept_viewer_invite(text) from public, anon;
grant execute on function public.mahjong_create_viewer_invite(uuid) to authenticated;
grant execute on function public.mahjong_accept_viewer_invite(text) to authenticated;

-- No direct table access is granted; authenticated viewer membership only grants SELECT
-- through the existing RLS. Existing snapshot-write RPC continues to enforce owner_id.
