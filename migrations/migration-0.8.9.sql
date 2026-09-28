-- ============================================================
--  DexCraft 0.8.9 — formes de Zarbi et nouveaux titres. UNE SEULE FOIS, sur le vrai Supabase,
--  APRÈS dexcraft-config.sql (27 formes de Zarbi, 5 titres), juste avant le push.
--  Relançable sans risque.
--
--  Recalcule tous les profils avec les nouvelles règles :
--  - titres affichés (shown) : Commun et Maître demandent maintenant aussi les formes de Zarbi ;
--    Alphabétiste, Évoli-fan, Pierre Stase, Baby-sitter et Archéologue sont attribués ; un titre qui n’est plus rempli disparaît ;
--  - détail par rareté du classement (byr) et date du titre Maître (masterTs, effacée si le titre est perdu).
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

select 'migration 0.8.9 OK' as verif,
  (select jsonb_array_length(data -> 'dexOrder') from public.game_config where id = 1) as cartes_du_pokedex,
  (select count(*) from public.docs where coll = 'players') as joueurs;
