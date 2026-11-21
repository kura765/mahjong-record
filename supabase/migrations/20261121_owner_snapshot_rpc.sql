-- v3.0 development-only: strengthen snapshot writes.
-- Apply AFTER 20261121_private_rooms_initial.sql in isolated mahjong-dev.
-- Direct client UPDATE is revoked. The only update path is the owner-checked RPC below.

revoke update on table public.mahjong_room_snapshots from authenticated;
drop policy if exists "snapshots_update_owner" on public.mahjong_room_snapshots;

create or replace function public.mahjong_write_snapshot(
  p_room_id uuid,
  p_expected_revision bigint,
  p_payload jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_revision bigint;
begin
  if (select auth.uid()) is null then
    raise exception 'ログインが必要です' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.mahjong_rooms r
    where r.id = p_room_id and r.owner_id = (select auth.uid())
  ) then
    raise exception '編集権限がありません' using errcode = '42501';
  end if;
  if p_expected_revision is null or p_expected_revision < 0 then
    raise exception '不正なバージョン番号です' using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 1048576 then
    raise exception '対局データの形式または容量が不正です' using errcode = '22023';
  end if;

  update public.mahjong_room_snapshots
  set payload = p_payload,
      revision = revision + 1,
      updated_by = (select auth.uid()),
      updated_at = now()
  where room_id = p_room_id and revision = p_expected_revision
  returning revision into new_revision;

  if new_revision is null then
    raise exception '別の更新が先に保存されました。最新版を再取得してください'
      using errcode = '40001';
  end if;
  return new_revision;
end;
$$;

revoke all on function public.mahjong_write_snapshot(uuid, bigint, jsonb) from public, anon;
grant execute on function public.mahjong_write_snapshot(uuid, bigint, jsonb) to authenticated;

-- Note: owner-only RPC still needs adversarial testing before deployment.
-- Realtime is deliberately NOT enabled here.
