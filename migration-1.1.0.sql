-- ============================================================
--  DexCraft — migration 1.1.0 (Shiny)
--  À lancer APRÈS dexcraft-config.sql et les trois parties serveur (dexcraft-serveur.sql, -2, -3).
--  Relançable sans danger.
--
--  Compteur « obtenue au total » (got) de chaque carte : le jeu ne gardait pas cet historique avant la 1.1.0, il part
--  donc des exemplaires actuels. Fusion : got[carte] = au moins le nombre d'exemplaires possédés (un joueur qui a déjà
--  ouvert des boosters entre le SQL et cette migration garde ce qu'il a gagné). Puis tous les profils sont recalculés.
-- ============================================================

update public.docs d
   set data = jsonb_set(d.data, '{got}',
         (case when jsonb_typeof(d.data -> 'got') = 'object' then d.data -> 'got' else '{}'::jsonb end)
         || coalesce((select jsonb_object_agg(c.key, greatest((c.value #>> '{}')::numeric::int, coalesce((d.data -> 'got' ->> c.key)::int, 0)))
                        from jsonb_each(d.data -> 'coll') c where jsonb_typeof(c.value) = 'number'), '{}'::jsonb)),
       updated_at = now()
 where d.coll = 'players';

update public.docs set data = public.dc__stamp(data, false), updated_at = now() where coll = 'players';

select 'migration 1.1.0 OK' as verif,
       count(*) filter (where jsonb_typeof(data -> 'got') = 'object') as joueurs_avec_compteur,
       count(*) as joueurs
  from public.docs where coll = 'players';
