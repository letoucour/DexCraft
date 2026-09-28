-- ============================================================
--  DexCraft 0.5.0 — suppression des enchères. UNE SEULE FOIS, sur le vrai Supabase, juste avant le push.
--  Chaque enchère encore en cours est annulée : la carte revient au vendeur,
--  la mise est rendue au meilleur enchérisseur. Puis les fonctions d'enchère sont supprimées.
--  Relançable sans risque (ne trouve plus rien la deuxième fois).
-- ============================================================
do $$
declare m record; o jsonb; n int := 0;
begin
  for m in select path, data from public.docs where coll = 'market' and data ->> 'kind' = 'a' for update loop
    if exists (select 1 from public.docs where path = 'players/' || (m.data ->> 'seller')) then
      o := public.dc__lock((m.data ->> 'seller')::uuid);
      perform public.dc__save((m.data ->> 'seller')::uuid, public.dc__add(o, public.dc__int(m.data, 'card')::int, 1), false);
    end if;
    if m.data ->> 'bidder' is not null and exists (select 1 from public.docs where path = 'players/' || (m.data ->> 'bidder')) then
      o := public.dc__lock((m.data ->> 'bidder')::uuid);
      perform public.dc__save((m.data ->> 'bidder')::uuid, jsonb_set(o, '{credits}', to_jsonb(public.dc__int(o, 'credits') + public.dc__int(m.data, 'bid'))), false);
    end if;
    delete from public.docs where path = m.path; n := n + 1;
  end loop;
  raise notice 'Enchères annulées : %', n;
end $$;

drop function if exists public.dc_auction_create(integer, bigint, numeric);
drop function if exists public.dc_bid(text, bigint);
drop function if exists public.dc_auction_cancel(text);
drop function if exists public.dc_auction_settle(text);

select 'migration 0.5.0 OK' as verif,
  (select count(*) from public.docs where coll = 'market' and data ->> 'kind' = 'a') as encheres_restantes,
  (select count(*) from pg_proc where proname in ('dc_auction_create', 'dc_bid', 'dc_auction_cancel', 'dc_auction_settle')) as fonctions_restantes;
