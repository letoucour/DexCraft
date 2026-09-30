-- ============================================================
--  DexCraft 1.5.0 — prestige. Sur le vrai Supabase, APRÈS dexcraft-config.sql, dexcraft-config-2.sql, dexcraft-config-3.sql,
--  dexcraft-serveur.sql et dexcraft-serveur-4.sql, juste avant le push. Relançable sans risque.
--
--  Le résumé du classement (colonne calculée summary, fonction dc__summary) contient désormais le prestige et le nombre de
--  boosters ouverts (tri du classement). PostgreSQL ne recalcule une colonne calculée qu'à l'écriture d'une ligne :
--  on réécrit donc chaque profil tel quel pour que tous les résumés soient à jour tout de suite.
-- ============================================================
update public.docs set data = data where coll = 'players';
select 'résumés du classement recalculés' as verif, count(*) as joueurs from public.docs where coll = 'players' and summary ? 'pseudo';
