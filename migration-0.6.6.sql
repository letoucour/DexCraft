-- ============================================================
--  DexCraft 0.6.6 — compteur de boosters ouverts rétroactif. UNE SEULE FOIS, sur le vrai Supabase.
--  Relançable sans risque (le compteur ne baisse jamais).
--
--  stats.packs n'existe que depuis les titres d'activité : les boosters ouverts avant n'ont pas été comptés.
--  Estimation à partir des cartes (5 par booster) : cartes possédées + cartes mises de côté au marché
--  (annonces et propositions) + cartes défaussées + 2 par évolution (3 cartes donnent 1 carte).
--  Le compteur prend la plus grande valeur entre l'actuelle et l'estimation. Les titres
--  « Déballeur », « Ouvre-boosters » et « Accro aux boosters » en profitent aussitôt.
-- ============================================================
do $$
declare p record; u text; cartes bigint; est bigint; cur bigint; n int := 0;
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    u := substr(p.path, 9);
    cartes := coalesce((select sum(value::bigint) from jsonb_each_text(p.data -> 'coll')), 0)
      + (select count(*) from public.docs m where m.coll = 'market' and m.data ->> 'owner' = u)
      + coalesce((select count(*) from public.docs m, jsonb_each(m.data -> 'offers') o
                  where m.coll = 'market' and o.value ->> 'by' = u and o.value ->> 'status' = 'pending'), 0)
      + coalesce((p.data -> 'stats' ->> 'discards')::bigint, 0)
      + 2 * coalesce((p.data -> 'stats' ->> 'evos')::bigint, 0);
    est := ceil(cartes / 5.0);
    cur := coalesce((p.data -> 'stats' ->> 'packs')::bigint, 0);
    if est > cur then
      update public.docs set data = public.dc__stamp(jsonb_set(p.data, '{stats,packs}', to_jsonb(est)), false), updated_at = now() where path = p.path;
      n := n + 1;
    end if;
  end loop;
  raise notice 'Compteurs de boosters rattrapés : %', n;
end $$;

select data ->> 'pseudo' as joueur, data -> 'stats' ->> 'packs' as boosters_ouverts
from public.docs where coll = 'players' order by (data -> 'stats' ->> 'packs')::bigint desc nulls last limit 20;
