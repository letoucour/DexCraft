-- ============================================================
--  DexCraft 1.1.7 — 35 nouvelles cartes (autres formes : Ursaking Lune Vermeille, Motisma, Lougaroc, Météno…).
--  UNE FOIS, sur le vrai Supabase, APRÈS dexcraft-config.sql, juste avant le push. Relançable sans risque.
--
--  Recalcule tous les profils avec le nouveau Pokédex (1 270 cartes) : titres affichés (Maître, Légendaire, Darwiniste…
--  demandent maintenant aussi les nouvelles cartes ; un titre qui n'est plus rempli disparaît), détail par rareté du
--  classement (byr) et date du titre Maître (masterTs, effacée si le titre est perdu).
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

select 'migration 1.1.7 OK' as verif,
  (select jsonb_array_length(data -> 'dexOrder') from public.game_config where id = 1) as cartes_du_pokedex,
  (select count(*) from public.docs where coll = 'players') as joueurs;
