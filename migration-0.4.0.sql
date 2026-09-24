-- ============================================================
--  DexCraft — migration vers la 0.4.0 (à lancer UNE SEULE FOIS, juste avant la mise en ligne)
--  Règle toutes les annonces de l'ancien système, puis vide le marché :
--   - enchère terminée avec une offre : crédits au vendeur, carte à l'acheteur ;
--   - échange accepté : chaque joueur reçoit la carte due ;
--   - tout le reste : cartes mises de côté et crédits bloqués rendus à leur propriétaire.
--  Aucune carte ni aucun crédit n'est perdu. Les profils sont conservés.
-- ============================================================
do $$
declare
  p record; l record; e record; m jsonb; o jsonb; d jsonb; now_ms bigint := public.dc__now();
  n_players int := 0; n_market int;
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    d := public.dc__norm(p.data);
    for l in select key, value from jsonb_each(coalesce(d -> 'listings', '{}')) loop
      if l.value ->> 'k' = 'o' then            -- proposition d'échange
        select data into m from public.docs where path = 'market/' || (l.value ->> 'm');
        o := m -> 'offers' -> l.key;
        if o ->> 'status' in ('accepted', 'claimed') then d := public.dc__add(d, public.dc__int(m, 'card')::int, 1);
        else d := public.dc__add(d, public.dc__int(l.value, 'c')::int, 1); end if;
      elsif l.value ->> 'k' = 'a' then         -- enchère mise en vente
        select data into m from public.docs where path = 'market/' || l.key;
        if m is not null and m ->> 'bidder' is not null and now_ms >= public.dc__int(m, 'endsAt') then
          d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + public.dc__int(m, 'bid')));
        else d := public.dc__add(d, public.dc__int(l.value, 'c')::int, 1); end if;
      else                                     -- annonce d'échange encore à soi
        d := public.dc__add(d, public.dc__int(l.value, 'c')::int, 1);
      end if;
    end loop;
    for e in select key, value from jsonb_each(coalesce(d -> 'escrow', '{}')) loop
      select data into m from public.docs where path = 'market/' || e.key;
      if m is not null and m ->> 'bidder' = substr(p.path, 9) and now_ms >= public.dc__int(m, 'endsAt') then
        d := public.dc__add(d, public.dc__int(m, 'card')::int, 1);   -- enchère remportée
      else
        d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + public.dc__int(e.value, 'a')));
      end if;
    end loop;
    d := d || jsonb_build_object('listings', '{}'::jsonb, 'escrow', '{}'::jsonb);
    update public.docs set data = public.dc__stamp(d, false), updated_at = now() where path = p.path;
    n_players := n_players + 1;
  end loop;
  select count(*) into n_market from public.docs where coll = 'market';
  delete from public.docs where coll = 'market';
  raise notice 'Migration 0.4.0 : % profils mis à jour, % annonces réglées.', n_players, n_market;
end $$;
select 'migration 0.4.0 OK' as verif, count(*) filter (where coll = 'players') as joueurs, count(*) filter (where coll = 'market') as annonces from public.docs;
