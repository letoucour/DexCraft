-- ============================================================
--  DexCraft 1.6.3 — UNE FOIS, sur le vrai Supabase, APRÈS dexcraft-serveur.sql à dexcraft-serveur-6.sql et la configuration.
--  Relancer ne donne rien de plus (marque « giftShiny » dans le profil).
--
--  1. Charme Chroma ramené de 40 à 15 rencontres par prestige (demande de Theo) : en contrepartie, chaque joueur actuel qui
--     n'a jamais passé de prestige reçoit 2 Boosters Shiny dans sa boîte cadeau. Les joueurs inscrits plus tard ne les ont pas.
--  2. Cartes spéciales (rareté 8) désormais impossibles à échanger : les annonces qui en proposent une sont retirées (carte
--     rendue à son propriétaire, propositions rendues à leurs auteurs), les propositions qui en offrent une sont retirées
--     (carte rendue à son auteur).
-- ============================================================
do $$
declare p record; m record; o record; n int := 0; na int := 0; np int := 0;
begin
  -- 1. cadeau : 2 Boosters Shiny
  for p in select path, data from public.docs where coll = 'players'
      and coalesce((data ->> 'prestige')::int, 0) = 0 and data ->> 'giftShiny' is null for update loop
    p.data := jsonb_set(p.data, '{gifts}', case when jsonb_typeof(p.data -> 'gifts') = 'array' then p.data -> 'gifts' else '[]' end
      || '[{"sp": "shiny", "v": 0, "n": 2}]'::jsonb) || jsonb_build_object('giftShiny', '1.6.3', 'updated', public.dc__now());
    update public.docs set data = p.data, updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  -- 2. annonces d'une carte spéciale : retirées par leur propriétaire
  for m in select substr(d.path, 8) mid, d.data ->> 'owner' owner from public.docs d
      join public.secret_cards c on c.id = (d.data ->> 'card')::int and c.data ->> 7 = '8'
      where d.coll = 'market' and d.data ->> 'status' = 'open' loop
    perform set_config('request.jwt.claim.sub', m.owner, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', m.owner)::text, true);
    perform public.dc_trade_cancel(m.mid);
    na := na + 1;
  end loop;
  -- propositions d'une carte spéciale : retirées par leur auteur
  for o in select substr(d.path, 8) mid, x.key oid, x.value ->> 'by' by_ from public.docs d, jsonb_each(coalesce(d.data -> 'offers', '{}')) x
      join public.secret_cards c on c.id = (x.value ->> 'card')::int and c.data ->> 7 = '8'
      where d.coll = 'market' and d.data ->> 'status' = 'open' and x.value ->> 'status' = 'pending' loop
    perform set_config('request.jwt.claim.sub', o.by_, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', o.by_)::text, true);
    perform public.dc_trade_withdraw(o.mid, o.oid);
    np := np + 1;
  end loop;
  raise notice 'Boosters Shiny offerts à % joueurs ; annonces de cartes spéciales retirées : % ; propositions retirées : %', n, na, np;
end $$;

select 'migration 1.6.3 OK' as verif,
  (select count(*) from public.docs where coll = 'players' and data ->> 'giftShiny' is not null) as joueurs_avec_le_cadeau,
  (select count(*) from public.docs where coll = 'players' and coalesce((data ->> 'prestige')::int, 0) > 0) as joueurs_prestige_sans_cadeau;
