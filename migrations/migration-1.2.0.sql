-- ============================================================
--  DexCraft 1.2.0 — nouvelles raretés. UNE SEULE FOIS, sur le vrai Supabase, APRÈS dexcraft-config.sql,
--  dexcraft-config-2.sql et dexcraft-serveur.sql, juste avant le push. Relançable sans risque.
--
--  30 Peu communes passent Communes et 30 Rares passent Épiques :
--  - tous les profils sont recalculés (détail par rareté du classement, titres Commun, Peu commun, Rare, Épique…) ;
--  - annonces d'échange ouvertes : rareté de la carte mise à jour ; une carte demandée qui n'a plus la même rareté
--    est retirée de la demande (liste de cartes, ou Pokémon précis) ; sans carte demandée restante, l'annonce
--    demande « n'importe quelle carte manquante » de sa rareté. Les propositions déjà faites restent.
-- ============================================================
do $$
declare p record; m record; cfg jsonb := public.dc__cfg(); r int; wl jsonb; nold int; n int := 0; k int := 0;
begin
  for p in select path from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(data, false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  for m in select path, data from public.docs where coll = 'market' and data ->> 'kind' = 't' and data ->> 'status' = 'open' for update loop
    r := public.dc__rar(cfg, (m.data ->> 'card')::int);
    wl := case when jsonb_typeof(m.data -> 'wantList') = 'array' then
      (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(m.data -> 'wantList') x where public.dc__rar(cfg, x::text::int) = r) end;
    nold := case when wl is null then 0 else jsonb_array_length(m.data -> 'wantList') end;   -- pas de CASE dans la condition d'un IF
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
  raise notice 'Profils recalculés : %, annonces corrigées : %', n, k;
end $$;

select 'migration 1.2.0 OK' as verif,
  (select jsonb_array_length(data -> 'byr' -> 0) from public.game_config where id = 1) as communes,
  (select jsonb_array_length(data -> 'byr' -> 3) from public.game_config where id = 1) as epiques,
  (select count(*) from public.docs where coll = 'players') as joueurs;
