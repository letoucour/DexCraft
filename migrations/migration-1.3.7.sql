-- ============================================================
--  DexCraft 1.3.7 — récompenses du jour augmentées, rattrapage des séries en cours.
--  UNE FOIS, sur le vrai Supabase, JUSTE AVANT dexcraft-config.sql (tant que l'ancien barème est en place :
--  une récompense récupérée avec le nouveau barème serait comptée deux fois). Relancer ne donne rien de plus
--  (marque « dailyRetro » dans le profil).
--
--  Pour chaque joueur dont la série est toujours en cours (dernière récompense aujourd'hui ou hier, heure de Paris),
--  les jours déjà récupérés de la série sont payés au nouveau barème : la différence va dans sa boîte cadeau.
--  Ancien barème (1.0.3) : boosters 1, 1, 2, 3, 5, 7, 10 ; crédits 300, 450, 650, 950, 1 400, 2 000, 3 000.
--  Nouveau (1.3.7)       : boosters 10, 15, 20, 25, 30, 40, 50 ; crédits 500, 700, 1 000, 1 400, 2 000, 2 800, 4 000.
-- ============================================================
do $$
declare p record; st int; pk int; cr bigint; n int := 0;
  dpk int[] := array[9, 14, 18, 22, 25, 33, 40];
  dcr int[] := array[200, 250, 350, 450, 600, 800, 1000];
  today text := public.dc__day(); yest text := to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD');
begin
  for p in select path, data from public.docs where coll = 'players'
      and data -> 'daily' ->> 'day' in (today, yest) and data ->> 'dailyRetro' is null for update loop
    st := least(7, greatest(0, coalesce((p.data -> 'daily' ->> 'streak')::int, 0)));
    continue when st = 0;
    select sum(dpk[i]), sum(dcr[i]) into pk, cr from generate_series(1, st) i;
    p.data := jsonb_set(p.data, '{gifts}', case when jsonb_typeof(p.data -> 'gifts') = 'array' then p.data -> 'gifts' else '[]' end
      || jsonb_build_array(jsonb_build_object('cr', cr), jsonb_build_object('pk', pk))) || '{"dailyRetro": "1.3.7"}';
    update public.docs set data = p.data, updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Séries rattrapées : %', n;
end $$;
