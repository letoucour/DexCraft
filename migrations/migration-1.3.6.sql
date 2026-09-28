-- ============================================================
--  DexCraft 1.3.6 — titres de l'Arène. Sur le vrai Supabase, APRÈS dexcraft-config.sql, dexcraft-config-2.sql,
--  dexcraft-config-3.sql et dexcraft-serveur-5.sql, juste avant le push. Relançable sans risque.
--
--  Gladiateur, Centurion, Imperator, Vainqueur de l'Arène et Conquérant se calculent sur les compteurs
--  arWins et arDone, tenus depuis l'ouverture de l'Arène (1.3.0) : rien à rattraper.
--  Invaincu (les 10 manches sans perdre une vie) est un nouveau drapeau : seule la dernière partie de chaque
--  joueur est gardée (ar_runs), on le donne donc à ceux dont la dernière partie terminée l'a été sans vie perdue.
--  Tous les profils sont recalculés (titres affichés des autres joueurs).
-- ============================================================
do $$
declare p record; lives int := coalesce((public.dc__cfg() -> 'arena' ->> 'lives')::int, 3); n int := 0; k int := 0;
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    if exists (select 1 from public.ar_runs r where 'players/' || r.uid::text = p.path
               and coalesce((r.data ->> 'over')::boolean, false) and (r.data ->> 'hp')::int >= lives) then
      p.data := jsonb_set(p.data || jsonb_build_object('stats', coalesce(p.data -> 'stats', '{}')), '{stats,arPerf}', '1');
      k := k + 1;
    end if;
    update public.docs set data = public.dc__stamp(p.data, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Profils recalculés : %, titre Invaincu rattrapé : %', n, k;
end $$;
