-- ============================================================
--  DexCraft 1.0.1 — Alpha testeur et Bêta testeur deviennent des badges (à droite du pseudo), plus des titres.
--  UNE SEULE FOIS, APRÈS dexcraft-config.sql, juste avant le push. Relançable sans risque.
--
--  Recalcule tous les profils avec la nouvelle configuration : « alpha » et « beta » quittent les titres choisis
--  (titles) et les titres affichés (shown). Les champs alpha et beta du profil restent : ce sont eux qui donnent les badges.
-- ============================================================
do $$
declare p record; n int := 0;
begin
  for p in select path from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(data, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Profils recalculés : %', n;
end $$;

select 'migration 1.0.1 OK' as verif,
  (select count(*) from public.docs where coll = 'players') as joueurs,
  (select count(*) from public.docs where coll = 'players' and (data -> 'titles' ?| array['alpha','beta'] or data -> 'shown' ?| array['alpha','beta'])) as titres_alpha_beta_restants,
  (select count(*) from public.docs where coll = 'players' and data ->> 'beta' = 'true') as badges_beta,
  (select count(*) from public.docs where coll = 'players' and data ->> 'alpha' = 'true') as badges_alpha;
