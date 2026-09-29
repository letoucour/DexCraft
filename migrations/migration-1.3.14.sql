-- ============================================================
--  DexCraft 1.3.14 — Fortuné devient le titre du Pack Or (article titre.fortune) ; les titres d'activité
--  Fortuné et Magnat (crédits détenus d'un coup) sont retirés. Sur le vrai Supabase, APRÈS dexcraft-config.sql,
--  dexcraft-config-2.sql et dexcraft-config-3.sql, juste avant le push. Relançable sans risque.
--
--  - les joueurs qui ont déjà le Pack Or reçoivent l'article titre.fortune (même date que leur dos Or) :
--    sans lui, la boutique leur reproposerait le pack, qui compte maintenant un article de plus ;
--  - tous les profils sont recalculés : les anciens titres Fortuné et Magnat quittent les titres affichés.
-- ============================================================
do $$
declare p record; n int := 0; k int := 0;
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    if coalesce(p.data -> 'cos', '{}') ? 'dos.or' and not coalesce(p.data -> 'cos', '{}') ? 'titre.fortune' then
      p.data := jsonb_set(p.data, '{cos,titre.fortune}', p.data -> 'cos' -> 'dos.or');
      k := k + 1;
    end if;
    update public.docs set data = public.dc__stamp(p.data, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Profils recalculés : %, titre Fortuné ajouté au Pack Or de % joueur(s)', n, k;
end $$;
