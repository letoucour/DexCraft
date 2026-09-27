-- ============================================================
--  DexCraft 1.0.0 — sortie de bêta. UNE SEULE FOIS, APRÈS dexcraft-config.sql, juste avant le push.
--  Relançable sans risque.
--
--  1. Tous les joueurs inscrits avant la 1.0.0 ont joué pendant la bêta : ils gardent le titre « Bêta testeur »
--     (beta = true dans leur profil). La configuration 1.0.0 ne le donne plus aux nouveaux comptes (betaOpen = false).
--  2. Recalcule tous les profils avec la nouvelle configuration : le titre « Secret », retiré du jeu, quitte
--     les titres choisis (titles) et les titres affichés à côté du nom (shown).
-- ============================================================
do $$
declare p record; n int := 0;
begin
  for p in select path from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(data || '{"beta": true}'::jsonb, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Profils recalculés : %', n;
end $$;

select 'migration 1.0.0 OK' as verif,
  (select count(*) from public.docs where coll = 'players') as joueurs,
  (select count(*) from public.docs where coll = 'players' and coalesce(data ->> 'beta', '') <> 'true') as sans_titre_beta,
  (select count(*) from public.docs where coll = 'players' and (data -> 'titles' ? 'secret' or data -> 'shown' ? 'secret')) as titre_secret_restant,
  (select (data ->> 'betaOpen') from public.game_config where id = 1) as beta_ouverte;
