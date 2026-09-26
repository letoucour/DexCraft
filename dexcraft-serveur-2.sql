-- ============================================================
--  DexCraft 0.4.0 — le serveur devient l'arbitre (anti-triche), PARTIE 2 / 2
--  À coller dans Supabase > SQL Editor > Run, APRÈS dexcraft-serveur.sql (partie 1).
--  Marché, VoltoBataille, outils administrateur, droits d'exécution. Relançable sans risque.
-- ============================================================
-- ============================================================
--  Enchères : retirées du jeu en 0.5.0 (les ventes en cours sont réglées par migration-0.5.0.sql)
-- ============================================================
drop function if exists public.dc_auction_create(integer, bigint, numeric);
drop function if exists public.dc_bid(text, bigint);
drop function if exists public.dc_auction_cancel(text);
drop function if exists public.dc_auction_settle(text);

-- ============================================================
--  Échanges
-- ============================================================
create or replace function public.dc_trade_create(p_card int, p_want int, p_mode text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); mid text := public.dc__mid();
begin
  if public.dc__count(d, p_card) < 1 then raise exception 'Vous ne possédez plus cette carte.'; end if;
  if p_want is not null and public.dc__rar(cfg, p_want) is distinct from public.dc__rar(cfg, p_card) then raise exception 'La carte demandée doit être de la même rareté.'; end if;
  d := public.dc__add(d, p_card, -1);
  insert into public.docs (path, coll, data) values ('market/' || mid, 'market', jsonb_build_object(
    'kind', 't', 'owner', u, 'card', p_card, 'rarity', public.dc__rar(cfg, p_card), 'want', p_want,
    'wantMode', case when p_want is null and p_mode = 'missing' then 'missing' end,
    'status', 'open', 'offers', '{}'::jsonb, 'created', public.dc__now()));
  return jsonb_build_object('profile', public.dc__save(u, d), 'mid', mid);
end $$;

create or replace function public.dc_trade_propose(p_mid text, p_card int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); cfg jsonb := public.dc__cfg(); d jsonb; ow jsonb; oid text := public.dc__mid();
begin
  if m is null or m ->> 'kind' <> 't' or m ->> 'status' <> 'open' then raise exception 'Cet échange n’est plus disponible.'; end if;
  if m ->> 'owner' = u::text then raise exception 'C’est votre propre annonce.'; end if;
  if public.dc__rar(cfg, p_card) is distinct from public.dc__rar(cfg, public.dc__int(m, 'card')::int) then raise exception 'Cette carte ne correspond pas à la demande.'; end if;
  if m ->> 'want' is not null and public.dc__int(m, 'want') <> p_card then raise exception 'Cette carte ne correspond pas à la demande.'; end if;
  if m ->> 'wantMode' = 'missing' then
    select data into ow from public.docs where path = 'players/' || (m ->> 'owner');
    -- « carte qui me manque » : si le propriétaire a déjà toutes les cartes de la rareté, n'importe laquelle est acceptée
    if public.dc__count(ow, p_card) > 0
       and coalesce((ow -> 'byr' ->> public.dc__rar(cfg, p_card))::int, 0) < jsonb_array_length(cfg -> 'byr' -> public.dc__rar(cfg, p_card)) then
      raise exception 'Le propriétaire possède déjà cette carte.';
    end if;
  end if;
  if exists (select 1 from jsonb_each(m -> 'offers') where value ->> 'by' = u::text and value ->> 'status' = 'pending') then
    raise exception 'Vous avez déjà une proposition en attente sur cet échange.';
  end if;
  d := public.dc__lock(u, true);
  if public.dc__count(d, p_card) < 1 then raise exception 'Vous ne possédez plus cette carte.'; end if;
  d := public.dc__add(d, p_card, -1);
  update public.docs set data = jsonb_set(m, '{offers}', (m -> 'offers') || jsonb_build_object(oid,
      jsonb_build_object('by', u, 'card', p_card, 'at', public.dc__now(), 'status', 'pending'))), updated_at = now()
    where path = 'market/' || p_mid;
  d := public.dc__save(u, d);
  if coalesce(m ->> 'auto', '') = 'true' then     -- acceptation automatique : l'échange se conclut tout de suite (0.7.1)
    perform public.dc__trade_accept(p_mid, oid);
    return jsonb_build_object('profile', (select data from public.docs where path = 'players/' || u), 'accepted', true, 'card', m -> 'card');
  end if;
  return jsonb_build_object('profile', d);
end $$;

create or replace function public.dc_trade_withdraw(p_mid text, p_oid text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); o jsonb; d jsonb;
begin
  o := m -> 'offers' -> p_oid;
  if o is null or o ->> 'by' <> u::text or o ->> 'status' <> 'pending' then raise exception 'Cette proposition a déjà été traitée.'; end if;
  d := public.dc__lock(u, true);
  update public.docs set data = jsonb_set(m, '{offers}', (m -> 'offers') - p_oid), updated_at = now() where path = 'market/' || p_mid;
  return jsonb_build_object('profile', public.dc__save(u, public.dc__add(d, public.dc__int(o, 'card')::int, 1)));
end $$;

-- rend les cartes des propositions en attente (sauf celle gardée) à leurs auteurs
create or replace function public.dc__return_offers(m jsonb, keep text) returns void language plpgsql volatile as $$
declare r record; o jsonb;
begin
  for r in select key, value from jsonb_each(m -> 'offers') where value ->> 'status' = 'pending' and key is distinct from keep loop
    o := public.dc__lock((r.value ->> 'by')::uuid);
    perform public.dc__save((r.value ->> 'by')::uuid, public.dc__add(o, public.dc__int(r.value, 'card')::int, 1), false);
  end loop;
end $$;

create or replace function public.dc_trade_answer(p_mid text, p_oid text, p_accept boolean) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); o jsonb; by_ uuid; d jsonb; p jsonb; us uuid[];
begin
  if m is null then raise exception 'Cette annonce n’existe plus.'; end if;
  if m ->> 'owner' <> u::text then raise exception 'Cette annonce n’est pas la vôtre.'; end if;
  o := m -> 'offers' -> p_oid;
  if o is null or o ->> 'status' <> 'pending' then raise exception 'Cette proposition n’est plus en attente.'; end if;
  by_ := (o ->> 'by')::uuid;
  if not p_accept then
    p := public.dc__lock(by_);
    perform public.dc__save(by_, public.dc__add(p, public.dc__int(o, 'card')::int, 1), false);
    update public.docs set data = jsonb_set(m, '{offers}', (m -> 'offers') - p_oid), updated_at = now() where path = 'market/' || p_mid;
    return jsonb_build_object('profile', public.dc__save(u, public.dc__lock(u, true), false), 'accepted', false);
  end if;
  perform public.dc__trade_accept(p_mid, p_oid);
  return jsonb_build_object('profile', public.dc__save(u, public.dc__lock(u, true)), 'accepted', true, 'card', o -> 'card');
end $$;

-- conclut un échange (proposition p_oid de l'annonce p_mid) : cartes échangées, autres propositions rendues,
-- annonce supprimée, historique. Utilisée par dc_trade_answer et par l'acceptation automatique (0.7.1).
create or replace function public.dc__trade_accept(p_mid text, p_oid text) returns void language plpgsql volatile as $$
declare m jsonb; o jsonb; by_ uuid; own uuid; us uuid[]; p jsonb; d jsonb;
begin
  select data into m from public.docs where path = 'market/' || p_mid for update;
  o := m -> 'offers' -> p_oid;
  if m is null or o is null or o ->> 'status' <> 'pending' then raise exception 'Cette proposition n’est plus en attente.'; end if;
  by_ := (o ->> 'by')::uuid; own := (m ->> 'owner')::uuid;
  select array_agg(distinct (value ->> 'by')::uuid) into us from jsonb_each(m -> 'offers') where value ->> 'status' = 'pending';
  perform public.dc__lock_many(coalesce(us, '{}') || own);
  perform public.dc__return_offers(m, p_oid);
  p := public.dc__lock(by_);
  perform public.dc__save(by_, public.dc__bump(public.dc__add(p, public.dc__int(m, 'card')::int, 1), 'trades'), false);
  d := public.dc__lock(own);
  perform public.dc__save(own, public.dc__bump(public.dc__add(d, public.dc__int(o, 'card')::int, 1), 'trades'), false);
  delete from public.docs where path = 'market/' || p_mid;
  -- historique : le propriétaire a donné m.card et reçu o.card
  insert into public.trade_log (owner, owner_card, taker, taker_card) values (own, public.dc__int(m, 'card')::int, by_, public.dc__int(o, 'card')::int);
end $$;

create or replace function public.dc_trade_cancel(p_mid text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); d jsonb; us uuid[];
begin
  if m is null then raise exception 'Cette annonce n’existe plus.'; end if;
  if m ->> 'owner' <> u::text then raise exception 'Cette annonce n’est pas la vôtre.'; end if;
  select array_agg(distinct (value ->> 'by')::uuid) into us from jsonb_each(m -> 'offers') where value ->> 'status' = 'pending';
  perform public.dc__lock_many(coalesce(us, '{}') || u);
  perform public.dc__return_offers(m, null);
  d := public.dc__lock(u, true);
  delete from public.docs where path = 'market/' || p_mid;
  return jsonb_build_object('profile', public.dc__save(u, public.dc__add(d, public.dc__int(m, 'card')::int, 1)));
end $$;

-- ============================================================
--  VoltoBataille : le plateau reste sur le serveur
-- ============================================================
create or replace function public.dc__vb_new(u uuid, lvl int) returns void language plpgsql volatile as $$
declare cfg jsonb := public.dc__cfg(); c jsonb; b int[] := '{}'; i int; j int; t int;
begin
  lvl := least(8, greatest(1, lvl));
  c := cfg -> 'vbLevels' -> lvl -> public.dc__rnd(5);
  for i in 1 .. (c ->> 0)::int loop b := b || 2; end loop;
  for i in 1 .. (c ->> 1)::int loop b := b || 3; end loop;
  for i in 1 .. (c ->> 2)::int loop b := b || 0; end loop;
  while coalesce(array_length(b, 1), 0) < 25 loop b := b || 1; end loop;
  for i in reverse 25 .. 2 loop j := public.dc__rnd(i) + 1; t := b[i]; b[i] := b[j]; b[j] := t; end loop;
  insert into public.vb_rounds (uid, level, board, opened, score, flipped, state, boom)
    values (u, lvl, b, array_fill(false, array[25]), 0, 0, 'play', null)
  on conflict (uid) do update set level = excluded.level, board = excluded.board, opened = excluded.opened,
    score = 0, flipped = 0, state = 'play', boom = null;
end $$;

-- ce que le joueur a le droit de voir : cartes retournées (tout à la fin de la manche) et indices
create or replace function public.dc__vb_view(u uuid, d jsonb) returns jsonb language plpgsql volatile as $$
declare v public.vb_rounds; vals jsonb := '[]'; rows_ jsonb := '[]'; cols jsonb := '[]'; i int; k int; pts int; vo int;
  gained bigint := case when d -> 'volto' ->> 'day' = public.dc__day() then public.dc__int(d -> 'volto', 'gained') else 0 end;
begin
  select * into v from public.vb_rounds where uid = u;
  for i in 1 .. 25 loop vals := vals || case when v.opened[i] or v.state <> 'play' then to_jsonb(v.board[i]) else 'null'::jsonb end; end loop;
  for k in 0 .. 4 loop
    pts := 0; vo := 0; for i in 1 .. 5 loop pts := pts + v.board[k * 5 + i]; if v.board[k * 5 + i] = 0 then vo := vo + 1; end if; end loop;
    rows_ := rows_ || jsonb_build_array(jsonb_build_array(pts, vo));
    pts := 0; vo := 0; for i in 0 .. 4 loop pts := pts + v.board[i * 5 + k + 1]; if v.board[i * 5 + k + 1] = 0 then vo := vo + 1; end if; end loop;
    cols := cols || jsonb_build_array(jsonb_build_array(pts, vo));
  end loop;
  return jsonb_build_object('level', v.level, 'score', v.score, 'flipped', v.flipped, 'state', v.state, 'boom', v.boom,
    'vals', vals, 'opened', to_jsonb(v.opened), 'rows', rows_, 'cols', cols, 'gained', gained, 'cap', public.dc__cfg() -> 'vbCap', 'day', public.dc__day());
end $$;

create or replace function public.dc_vb_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true);
begin
  if not exists (select 1 from public.vb_rounds where uid = u) then perform public.dc__vb_new(u, public.dc__int(d -> 'volto', 'level')::int); end if;
  return jsonb_build_object('vb', public.dc__vb_view(u, d));
end $$;

create or replace function public.dc_vb_next() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); lvl int;
begin
  select level into lvl from public.vb_rounds where uid = u and state <> 'play';
  if not found then select level into lvl from public.vb_rounds where uid = u; end if;
  if lvl is null then lvl := public.dc__int(d -> 'volto', 'level')::int; end if;
  if exists (select 1 from public.vb_rounds where uid = u and state = 'play' and score = 0 and flipped = 0) then
    return jsonb_build_object('vb', public.dc__vb_view(u, d));   -- manche vierge déjà en cours
  end if;
  if exists (select 1 from public.vb_rounds where uid = u and state = 'play') then raise exception 'Terminez d’abord la manche en cours.'; end if;
  perform public.dc__vb_new(u, lvl);
  return jsonb_build_object('vb', public.dc__vb_view(u, d));
end $$;

-- fin de manche : crédits dans la limite du jour, niveau, compteurs
create or replace function public.dc__vb_end(u uuid, d jsonb, v public.vb_rounds, kind text) returns jsonb language plpgsql volatile as $$
declare cap bigint := (public.dc__cfg() ->> 'vbCap')::bigint; day text := public.dc__day();
  gained bigint := case when d -> 'volto' ->> 'day' = day then public.dc__int(d -> 'volto', 'gained') else 0 end;
  added bigint := 0; nl int;
begin
  nl := case when kind = 'won' then least(8, v.level + 1) else greatest(1, least(v.level, v.flipped)) end;
  if kind <> 'lost' and v.score > 0 then added := least(v.score, greatest(0, cap - gained)); end if;
  d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + added));
  d := jsonb_set(d, '{volto}', jsonb_build_object('day', day, 'gained', gained + added, 'level', nl));
  if kind = 'won' then
    d := public.dc__bump(d, 'vbWins');
    if v.level = 8 then d := jsonb_set(d, '{stats,vbL8}', '1'); end if;
  end if;
  update public.vb_rounds set state = kind, level = nl where uid = u;
  d := public.dc__save(u, d);
  return jsonb_build_object('profile', d, 'added', added, 'kind', kind, 'prevLevel', v.level, 'level', nl, 'score', v.score);
end $$;

create or replace function public.dc_vb_flip(p_i int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); v public.vb_rounds; val int; res jsonb := '{}'; i int; all_ boolean := true;
begin
  if p_i < 0 or p_i > 24 then raise exception 'Carte invalide.'; end if;
  select * into v from public.vb_rounds where uid = u for update;
  if not found or v.state <> 'play' or v.opened[p_i + 1] then return jsonb_build_object('vb', public.dc__vb_view(u, d)); end if;
  val := v.board[p_i + 1]; v.opened[p_i + 1] := true;
  if val = 0 then
    update public.vb_rounds set opened = v.opened, boom = p_i where uid = u;
    res := public.dc__vb_end(u, d, v, 'lost');
  else
    v.flipped := v.flipped + 1; v.score := case when v.score = 0 then val else v.score * val end;
    update public.vb_rounds set opened = v.opened, flipped = v.flipped, score = v.score where uid = u;
    for i in 1 .. 25 loop if v.board[i] >= 2 and not v.opened[i] then all_ := false; exit; end if; end loop;
    if all_ then res := public.dc__vb_end(u, d, v, 'won'); end if;
  end if;
  d := coalesce(res -> 'profile', d);
  return res || jsonb_build_object('vb', public.dc__vb_view(u, d), 'val', val);
end $$;

create or replace function public.dc_vb_quit() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); v public.vb_rounds; res jsonb;
begin
  select * into v from public.vb_rounds where uid = u for update;
  if not found or v.state <> 'play' or v.score = 0 then raise exception 'Rien à encaisser pour l’instant.'; end if;
  res := public.dc__vb_end(u, d, v, 'quit');
  return res || jsonb_build_object('vb', public.dc__vb_view(u, res -> 'profile'));
end $$;

-- ============================================================
--  Outils administrateur (table admins)
-- ============================================================
create or replace function public.dc__admin() returns uuid language plpgsql stable as $$
declare u uuid := public.dc__uid();
begin
  if not public.dc__is_admin(u) then raise exception 'Réservé à l’administrateur.'; end if;
  return u;
end $$;

create or replace function public.dc_admin_toggle_dev() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__admin(); d jsonb := public.dc__lock(u, true);
begin
  return jsonb_build_object('profile', public.dc__save(u, jsonb_set(d, '{dev}', to_jsonb(not coalesce((d ->> 'dev')::boolean, false)))));
end $$;

create or replace function public.dc_admin_grant(p_uid uuid, p_cr bigint, p_pk int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(p_uid, p_uid = a); g jsonb; cr bigint := coalesce(p_cr, 0); pk int := coalesce(p_pk, 0);
begin
  -- dons (valeurs positives) : dans la boîte cadeau du joueur, qu'il ouvre depuis l'écran des boosters (dc_gift_open, partie 3)
  g := case when jsonb_typeof(d -> 'gifts') = 'array' then d -> 'gifts' else '[]' end;
  if cr > 0 then g := g || jsonb_build_array(jsonb_build_object('cr', cr)); end if;
  if pk > 0 then g := g || jsonb_build_array(jsonb_build_object('pk', pk)); end if;
  if cr > 0 or pk > 0 then d := jsonb_set(d, '{gifts}', g); end if;
  -- retraits (valeurs négatives) : directement, sans descendre sous zéro
  d := d || jsonb_build_object('credits', greatest(0, public.dc__int(d, 'credits') + least(cr, 0)), 'bonus', greatest(0, public.dc__int(d, 'bonus') + least(pk, 0)));
  d := public.dc__save(p_uid, d, p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end, 'gift', cr > 0 or pk > 0);
end $$;

create or replace function public.dc_admin_badge(p_uid uuid, p_on boolean) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(p_uid, p_uid = a);
begin
  if coalesce((d ->> 'alpha')::boolean, false) = p_on then raise exception '%', case when p_on then 'Ce joueur a déjà le badge.' else 'Ce joueur n’a pas le badge.' end; end if;
  d := public.dc__save(p_uid, jsonb_set(d, '{alpha}', to_jsonb(p_on)), p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end);
end $$;

create or replace function public.dc_admin_pseudo(p_uid uuid, p_v text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(p_uid, p_uid = a);
begin
  if btrim(coalesce(p_v, '')) = '' then   -- pseudo effacé : pseudo provisoire, le joueur devra en choisir un à sa prochaine connexion
    d := d || jsonb_build_object('pseudo', 'Dresseur ' || lpad(public.dc__rnd(10000)::text, 4, '0'), 'pseudoSet', false);
  else                                    -- mêmes règles que pour les joueurs (unique, pas d'insulte), noms réservés permis
    d := d || jsonb_build_object('pseudo', public.dc__pseudo_check(p_v, p_uid, true), 'pseudoSet', true);
  end if;
  d := public.dc__save(p_uid, d, p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end);
end $$;

-- remise à zéro de son propre profil (full : pseudo et image compris)
create or replace function public.dc_admin_reset_me(p_full boolean) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(a, true); m record; keep jsonb;
begin
  for m in select path, data from public.docs where coll = 'market' and (data ->> 'seller' = a::text or data ->> 'owner' = a::text) for update loop
    if m.data ->> 'kind' = 'a' and m.data ->> 'bidder' is not null then   -- rembourse l'enchérisseur
      perform public.dc__save((m.data ->> 'bidder')::uuid, jsonb_set(public.dc__lock((m.data ->> 'bidder')::uuid), '{credits}',
        to_jsonb(public.dc__int(public.dc__lock((m.data ->> 'bidder')::uuid), 'credits') + public.dc__int(m.data, 'bid'))), false);
    elsif m.data ->> 'kind' = 't' then perform public.dc__return_offers(m.data, null); end if;
    delete from public.docs where path = m.path;
  end loop;
  keep := jsonb_build_object('dev', d -> 'dev', 'alpha', d -> 'alpha', 'beta', d -> 'beta');
  if not p_full then keep := keep || jsonb_build_object('pseudo', d -> 'pseudo', 'pseudoTs', d -> 'pseudoTs', 'pseudoSet', d -> 'pseudoSet'); end if;
  delete from public.vb_rounds where uid = a;
  d := public.dc__norm(keep);
  update public.docs set data = d where path = 'players/' || a;
  return jsonb_build_object('profile', public.dc__save(a, d));
end $$;

create or replace function public.dc_admin_reset_once() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(a, true);
begin
  return jsonb_build_object('profile', public.dc__save(a, jsonb_set(d, '{bought}', '{}')));
end $$;

-- vide le marché en rendant cartes et crédits engagés
create or replace function public.dc_admin_clear_market() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); m record; o jsonb; n int := 0;
begin
  for m in select path, data from public.docs where coll = 'market' for update loop
    if m.data ->> 'kind' = 'a' then
      o := public.dc__lock((m.data ->> 'seller')::uuid);
      perform public.dc__save((m.data ->> 'seller')::uuid, public.dc__add(o, public.dc__int(m.data, 'card')::int, 1), false);
      if m.data ->> 'bidder' is not null then
        o := public.dc__lock((m.data ->> 'bidder')::uuid);
        perform public.dc__save((m.data ->> 'bidder')::uuid, jsonb_set(o, '{credits}', to_jsonb(public.dc__int(o, 'credits') + public.dc__int(m.data, 'bid'))), false);
      end if;
    else
      perform public.dc__return_offers(m.data, null);
      o := public.dc__lock((m.data ->> 'owner')::uuid);
      perform public.dc__save((m.data ->> 'owner')::uuid, public.dc__add(o, public.dc__int(m.data, 'card')::int, 1), false);
    end if;
    delete from public.docs where path = m.path; n := n + 1;
  end loop;
  return jsonb_build_object('profile', (select data from public.docs where path = 'players/' || a), 'n', n);
end $$;

-- remise à zéro générale : compte neuf, en gardant pseudo, titres Alpha et Bêta et mode développeur
create or replace function public.dc_admin_reset_all() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); p record; n int := 0;
begin
  delete from public.docs where coll = 'market';
  delete from public.vb_rounds;
  for p in select path, data from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(public.dc__norm(jsonb_build_object('pseudo', p.data -> 'pseudo', 'pseudoTs', p.data -> 'pseudoTs',
      'pseudoSet', p.data -> 'pseudoSet', 'alpha', p.data -> 'alpha', 'beta', p.data -> 'beta', 'dev', p.data -> 'dev')), false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  return jsonb_build_object('profile', (select data from public.docs where path = 'players/' || a), 'n', n);
end $$;

create or replace function public.dc_admin_fill_packs() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); p record; n int := 0; mx jsonb := public.dc__cfg() -> 'maxp';
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    update public.docs set data = public.dc__stamp(p.data || jsonb_build_object('packs', mx, 'packTs', public.dc__now()), false), updated_at = now() where path = p.path;
    n := n + 1;
  end loop;
  return jsonb_build_object('profile', (select data from public.docs where path = 'players/' || a), 'n', n);
end $$;

create or replace function public.dc_admin_buy_credits(p_i int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(a, true); c bigint := (public.dc__cfg() -> 'creditPacks' ->> p_i)::bigint;
begin
  if c is null or not coalesce((d ->> 'dev')::boolean, false) then raise exception 'Mode développeur requis.'; end if;
  return jsonb_build_object('profile', public.dc__save(a, jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + c))));
end $$;

-- ============================================================
--  Droits d'exécution : seules les fonctions dc_* sont appelables par les joueurs connectés,
--  les fonctions dc__* restent internes.
-- ============================================================
revoke all on function public.dc__add(jsonb,integer,integer) from public, anon, authenticated;
revoke all on function public.dc__admin() from public, anon, authenticated;
revoke all on function public.dc__bump(jsonb,text,bigint) from public, anon, authenticated;
revoke all on function public.dc__cfg() from public, anon, authenticated;
revoke all on function public.dc__count(jsonb,integer) from public, anon, authenticated;
revoke all on function public.dc__day() from public, anon, authenticated;
revoke all on function public.dc__int(jsonb,text) from public, anon, authenticated;
revoke all on function public.dc__is_admin(uuid) from public, anon, authenticated;
revoke all on function public.dc__lock(uuid,boolean) from public, anon, authenticated;
revoke all on function public.dc__lock_many(uuid[]) from public, anon, authenticated;
revoke all on function public.dc__market(text) from public, anon, authenticated;
revoke all on function public.dc__mid() from public, anon, authenticated;
revoke all on function public.dc__norm(jsonb) from public, anon, authenticated;
revoke all on function public.dc__now() from public, anon, authenticated;
revoke all on function public.dc__packinfo(jsonb,bigint) from public, anon, authenticated;
revoke all on function public.dc__rar(jsonb,integer) from public, anon, authenticated;
revoke all on function public.dc__return_offers(jsonb,text) from public, anon, authenticated;
revoke all on function public.dc__trade_accept(text,text) from public, anon, authenticated;
revoke all on function public.dc__rnd(integer) from public, anon, authenticated;
revoke all on function public.dc__save(uuid,jsonb,boolean) from public, anon, authenticated;
revoke all on function public.dc__stamp(jsonb,boolean) from public, anon, authenticated;
revoke all on function public.dc__uid() from public, anon, authenticated;
revoke all on function public.dc__vb_end(uuid,jsonb,vb_rounds,text) from public, anon, authenticated;
revoke all on function public.dc__vb_new(uuid,integer) from public, anon, authenticated;
revoke all on function public.dc__vb_view(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.dc_admin_badge(uuid,boolean) from public, anon;
grant execute on function public.dc_admin_badge(uuid,boolean) to authenticated;
revoke all on function public.dc_admin_buy_credits(integer) from public, anon;
grant execute on function public.dc_admin_buy_credits(integer) to authenticated;
revoke all on function public.dc_admin_clear_market() from public, anon;
grant execute on function public.dc_admin_clear_market() to authenticated;
revoke all on function public.dc_admin_fill_packs() from public, anon;
grant execute on function public.dc_admin_fill_packs() to authenticated;
revoke all on function public.dc_admin_grant(uuid,bigint,integer) from public, anon;
grant execute on function public.dc_admin_grant(uuid,bigint,integer) to authenticated;
revoke all on function public.dc_admin_pseudo(uuid,text) from public, anon;
grant execute on function public.dc_admin_pseudo(uuid,text) to authenticated;
revoke all on function public.dc_admin_reset_all() from public, anon;
grant execute on function public.dc_admin_reset_all() to authenticated;
revoke all on function public.dc_admin_reset_me(boolean) from public, anon;
grant execute on function public.dc_admin_reset_me(boolean) to authenticated;
revoke all on function public.dc_admin_reset_once() from public, anon;
grant execute on function public.dc_admin_reset_once() to authenticated;
revoke all on function public.dc_admin_toggle_dev() from public, anon;
grant execute on function public.dc_admin_toggle_dev() to authenticated;
revoke all on function public.dc_buy_once(text) from public, anon;
grant execute on function public.dc_buy_once(text) to authenticated;
revoke all on function public.dc_buy_packs(integer) from public, anon;
grant execute on function public.dc_buy_packs(integer) to authenticated;
revoke all on function public.dc_discard(jsonb) from public, anon;
grant execute on function public.dc_discard(jsonb) to authenticated;
revoke all on function public.dc_evolve(integer,integer) from public, anon;
grant execute on function public.dc_evolve(integer,integer) to authenticated;
revoke all on function public.dc_init() from public, anon;
grant execute on function public.dc_init() to authenticated;
revoke all on function public.dc_open(integer) from public, anon;
grant execute on function public.dc_open(integer) to authenticated;
revoke all on function public.dc_quick_evo() from public, anon;
grant execute on function public.dc_quick_evo() to authenticated;
revoke all on function public.dc_set_avatar(integer) from public, anon;
grant execute on function public.dc_set_avatar(integer) to authenticated;
revoke all on function public.dc_set_pseudo(text) from public, anon;
grant execute on function public.dc_set_pseudo(text) to authenticated;
revoke all on function public.dc_set_titles(jsonb) from public, anon;
grant execute on function public.dc_set_titles(jsonb) to authenticated;
revoke all on function public.dc_toggle_fav(integer) from public, anon;
grant execute on function public.dc_toggle_fav(integer) to authenticated;
revoke all on function public.dc_trade_answer(text,text,boolean) from public, anon;
grant execute on function public.dc_trade_answer(text,text,boolean) to authenticated;
revoke all on function public.dc_trade_cancel(text) from public, anon;
grant execute on function public.dc_trade_cancel(text) to authenticated;
revoke all on function public.dc_trade_create(integer,integer,text) from public, anon;
grant execute on function public.dc_trade_create(integer,integer,text) to authenticated;
revoke all on function public.dc_trade_propose(text,integer) from public, anon;
grant execute on function public.dc_trade_propose(text,integer) to authenticated;
revoke all on function public.dc_trade_withdraw(text,text) from public, anon;
grant execute on function public.dc_trade_withdraw(text,text) to authenticated;
revoke all on function public.dc_vb_flip(integer) from public, anon;
grant execute on function public.dc_vb_flip(integer) to authenticated;
revoke all on function public.dc_vb_next() from public, anon;
grant execute on function public.dc_vb_next() to authenticated;
revoke all on function public.dc_vb_quit() from public, anon;
grant execute on function public.dc_vb_quit() to authenticated;
revoke all on function public.dc_vb_state() from public, anon;
grant execute on function public.dc_vb_state() to authenticated;

select 'serveur DexCraft 0.4.0 OK' as verif, count(*) as fonctions from pg_proc where proname like 'dc\_%';