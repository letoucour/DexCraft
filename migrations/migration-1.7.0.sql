-- ============================================================
--  DexCraft 1.7.0 — nouvelles raretés. UNE FOIS, sur le vrai Supabase, APRÈS la configuration et les parties du serveur
--  (outils\passer-sql.ps1 la passe d'office à la fin). Relançable sans risque.
--
--  Caninos (et Caninos de Hisui), Métamorph, Évoli, Griknot et Riolu passent Peu communes ; Mimiqui et Carmache passent Rares
--  (demande de Theo) :
--  - tous les profils sont recalculés (détail par rareté du classement, titres Commun, Peu commun, Rare…) ;
--  - annonces d'échange ouvertes : rareté de la carte mise à jour ; une carte demandée qui n'a plus la même rareté est retirée
--    de la demande (liste de cartes, ou Pokémon précis) ; sans carte demandée restante, l'annonce demande « n'importe quelle carte
--    manquante » de sa rareté (comme la migration 1.2.0) ;
--  - propositions en attente dont la carte n'a plus la rareté de l'annonce : retirées, la carte revient à son auteur.
-- ============================================================
do $$
declare p record; m record; o record; cfg jsonb := public.dc__cfg(); r int; wl jsonb; nold int; n int := 0; k int := 0; np int := 0;
begin
  for p in select path from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(data, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  for m in select path, data from public.docs where coll = 'market' and data ->> 'kind' = 't' and data ->> 'status' = 'open' for update loop
    r := public.dc__rar(cfg, (m.data ->> 'card')::int);
    wl := case when jsonb_typeof(m.data -> 'wantList') = 'array' then
      (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(m.data -> 'wantList') x where public.dc__rar(cfg, x::text::int) = r) end;
    nold := case when wl is null then 0 else jsonb_array_length(m.data -> 'wantList') end;
    if (m.data ->> 'rarity')::int is distinct from r
       or (m.data ->> 'want' is not null and public.dc__rar(cfg, (m.data ->> 'want')::int) is distinct from r)
       or coalesce(jsonb_array_length(wl), 0) <> nold then
      m.data := m.data || jsonb_build_object('rarity', r);
      if m.data ->> 'want' is not null and public.dc__rar(cfg, (m.data ->> 'want')::int) is distinct from r then
        m.data := m.data || '{"want": null, "wantMode": "missing"}'; end if;
      if wl is not null then
        m.data := m.data || case jsonb_array_length(wl)
          when 0 then '{"wantList": null, "wantMode": "missing"}'::jsonb
          when 1 then jsonb_build_object('wantList', null, 'want', wl -> 0)
          else jsonb_build_object('wantList', wl) end;
      end if;
      update public.docs set data = m.data, updated_at = now() where path = m.path;
      k := k + 1;
    end if;
  end loop;
  -- propositions devenues d'une autre rareté que l'annonce : retirées par leur auteur (carte rendue)
  for o in select substr(x.path, 8) mid, f.key oid, f.value ->> 'by' by_ from public.docs x, jsonb_each(coalesce(x.data -> 'offers', '{}')) f
      where x.coll = 'market' and x.data ->> 'status' = 'open' and f.value ->> 'status' = 'pending'
        and public.dc__rar(cfg, (f.value ->> 'card')::int) is distinct from public.dc__rar(cfg, (x.data ->> 'card')::int) loop
    perform set_config('request.jwt.claim.sub', o.by_, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', o.by_)::text, true);
    perform public.dc_trade_withdraw(o.mid, o.oid);
    np := np + 1;
  end loop;
  raise notice 'Profils recalculés : %, annonces corrigées : %, propositions rendues : %', n, k, np;
end $$;

select 'migration 1.7.0 OK' as verif,
  (select data -> 'rar' ->> '133' from public.game_config where id = 1) as rarete_evoli_1,
  (select data -> 'rar' ->> '778' from public.game_config where id = 1) as rarete_mimiqui_2,
  (select count(*) from public.docs where coll = 'players') as joueurs;
