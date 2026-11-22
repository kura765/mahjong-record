-- v3.0 development only. Run in mahjong-dev SQL Editor after RLS migrations.
-- Supabase Realtime Postgres Changes delivers snapshot events only to sessions
-- that satisfy the existing SELECT row-level security policy.
-- Do NOT grant anon access or disable RLS.
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='mahjong_room_snapshots'
  ) then
    alter publication supabase_realtime add table public.mahjong_room_snapshots;
  end if;
end $$;
-- Only UPDATE/INSERT payloads (no previous-row disclosure required).
-- Keep replica identity DEFAULT. Never use FULL for this feature.
