-- ============================================================
--  DexCraft 0.4.0 — le serveur devient l'arbitre (anti-triche)
--  À coller dans Supabase > SQL Editor > Run, APRÈS dexcraft-supabase.sql et dexcraft-config.sql.
--  Relançable sans risque. Les profils ne sont jamais effacés.
--
--  Principe : les joueurs ne peuvent plus écrire eux-mêmes dans public.docs.
--  Chaque action du jeu est une fonction dc_* qui vérifie tout, tire le hasard ici,
--  puis enregistre. Les fonctions dc__* sont internes (non appelables par les joueurs).
-- ============================================================

-- ---------- tables ----------
create table if not exists public.vb_rounds (      -- manches de VoltoBataille : plateau caché aux joueurs
  uid     uuid primary key,
  level   int not null default 1,
  board   int[] not null,
  opened  boolean[] not null,
  score   bigint not null default 0,
  flipped int not null default 0,
  state   text not null default 'play',
  boom    int
);
alter table public.vb_rounds enable row level security;
alter table public.game_config enable row level security;
revoke all on public.vb_rounds, public.game_config from anon, authenticated;

-- ---------- droits : lecture seule pour les joueurs ----------
drop policy if exists docs_write on public.docs;
drop policy if exists docs_read  on public.docs;
create policy docs_read on public.docs for select to authenticated using (true);
revoke insert, update, delete on public.docs from anon, authenticated;
grant select on public.docs to authenticated;

-- ============================================================
--  Outils internes
-- ============================================================
create or replace function public.dc__cfg() returns jsonb language sql stable as
$$ select data from public.game_config where id = 1 $$;

create or replace function public.dc__now() returns bigint language sql volatile as
$$ select (extract(epoch from clock_timestamp()) * 1000)::bigint $$;

create or replace function public.dc__day() returns text language sql stable as
$$ select to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD') $$;

-- entier au hasard dans [0, n[, sans biais (tirage par rejet), hasard cryptographique
create or replace function public.dc__rnd(n int) returns int language plpgsql volatile as $$
declare mx bigint := (4294967296 / n) * n; v bigint;
begin
  loop
    v := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    if v < 0 then v := v + 4294967296; end if;
    exit when v < mx;
  end loop;
  return (v % n)::int;
end $$;

create or replace function public.dc__uid() returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Connectez-vous pour jouer.'; end if;
  return u;
end $$;

create or replace function public.dc__is_admin(u uuid) returns boolean language sql stable as
$$ select exists (select 1 from public.admins a where a.uid = u) $$;

create or replace function public.dc__int(d jsonb, k text) returns bigint language sql immutable as
$$ select case when jsonb_typeof(d -> k) = 'number' then floor((d ->> k)::numeric)::bigint else 0 end $$;

create or replace function public.dc__count(d jsonb, id int) returns int language sql immutable as
$$ select coalesce((d -> 'coll' ->> id::text)::int, 0) $$;

create or replace function public.dc__add(d jsonb, id int, n int) returns jsonb language plpgsql immutable as $$
declare k text := id::text; c int := coalesce((d -> 'coll' ->> k)::int, 0) + n;
begin
  if c < 0 then raise exception 'Carte absente de la collection.'; end if;
  if c = 0 then return jsonb_set(d, '{coll}', coalesce(d -> 'coll', '{}') - k); end if;
  return jsonb_set(d, '{coll}', coalesce(d -> 'coll', '{}') || jsonb_build_object(k, c));
end $$;

create or replace function public.dc__bump(d jsonb, k text, n bigint default 1) returns jsonb language sql immutable as
$$ select jsonb_set(d, '{stats}', coalesce(d -> 'stats', '{}') || jsonb_build_object(k, coalesce((d -> 'stats' ->> k)::bigint, 0) + n)) $$;

create or replace function public.dc__rar(cfg jsonb, id int) returns int language sql immutable as
$$ select (cfg -> 'rar' ->> id::text)::int $$;

-- profil complet avec toutes ses valeurs par défaut
create or replace function public.dc__norm(d jsonb) returns jsonb language plpgsql volatile as $$
declare cfg jsonb := public.dc__cfg();
begin
  d := jsonb_build_object('coll', '{}'::jsonb, 'listings', '{}'::jsonb, 'escrow', '{}'::jsonb, 'bought', '{}'::jsonb,
         'fav', '{}'::jsonb, 'stats', '{}'::jsonb, 'volto', jsonb_build_object('day', '', 'gained', 0, 'level', 1),
         'credits', cfg -> 'startCredits', 'packs', cfg -> 'maxp', 'packTs', public.dc__now(), 'bonus', 0,
         'avatar', null, 'pseudo', '', 'dev', false, 'alpha', false, 'created', public.dc__now())
       || coalesce(d, '{}'::jsonb);
  if jsonb_typeof(d -> 'volto') <> 'object' then d := jsonb_set(d, '{volto}', jsonb_build_object('day', '', 'gained', 0, 'level', 1)); end if;
  if jsonb_typeof(d -> 'stats') <> 'object' then d := jsonb_set(d, '{stats}', '{}'); end if;
  return d;
end $$;

-- champs calculés (classement, titres…) : jamais fournis par le joueur
create or replace function public.dc__stamp(d jsonb, own boolean) returns jsonb language plpgsql volatile as $$
declare
  cfg jsonb := public.dc__cfg(); r record; n int; rr int;
  newcoll jsonb := '{}'; byr int[] := array[0,0,0,0,0,0,0,0];
  uniq int := 0; myth int := 0; trans int := 0; tot bigint := 0; nmaster int := 0;
  now_ms bigint := public.dc__now(); tk jsonb;
begin
  d := public.dc__norm(d);
  for r in select key, value from jsonb_each(d -> 'coll') loop
    if jsonb_typeof(r.value) <> 'number' then continue; end if;
    n := floor((r.value #>> '{}')::numeric)::int;
    rr := public.dc__rar(cfg, r.key::int);
    if n <= 0 or rr is null then continue; end if;
    newcoll := newcoll || jsonb_build_object(r.key, n);
    byr[rr + 1] := byr[rr + 1] + 1; tot := tot + n;
    if r.key::int <= 1025 then uniq := uniq + 1; end if;
    if rr = 6 then myth := myth + 1; elsif rr = 7 then trans := trans + 1; end if;
    if rr <= 5 then nmaster := nmaster + 1; end if;
  end loop;
  d := d || jsonb_build_object('coll', newcoll, 'unique', uniq, 'myth', myth, 'trans', trans,
         'byr', to_jsonb(byr), 'byrV', cfg -> 'byrV', 'total', tot, 'listings', '{}'::jsonb, 'escrow', '{}'::jsonb);
  if d ->> 'avatar' is not null and not (newcoll ? (d ->> 'avatar')) then d := jsonb_set(d, '{avatar}', 'null'); end if;
  d := jsonb_set(d, '{fav}', coalesce((select jsonb_object_agg(key, value) from jsonb_each(d -> 'fav') where newcoll ? key), '{}'));
  if (cfg ->> 'betaOpen')::boolean then d := jsonb_set(d, '{beta}', 'true'); end if;
  if public.dc__int(d, 'credits') > coalesce((d -> 'stats' ->> 'maxCr')::bigint, 0) then
    d := jsonb_set(d, '{stats,maxCr}', to_jsonb(public.dc__int(d, 'credits')));
  end if;
  if nmaster = jsonb_array_length(cfg -> 'dexOrder') then
    if d -> 'masterTs' is null or d -> 'masterTs' = 'null' then d := jsonb_set(d, '{masterTs}', to_jsonb(now_ms)); end if;
  else d := d - 'masterTs'; end if;
  if jsonb_typeof(d -> 'titles') = 'array' then
    select coalesce(jsonb_agg(v), '[]') into tk from (
      select v from jsonb_array_elements(d -> 'titles') v where cfg -> 'titleKeys' @> jsonb_build_array(v) limit (cfg ->> 'titleMax')::int) s;
    d := jsonb_set(d, '{titles}', tk);
  elsif d ? 'titles' then d := d - 'titles'; end if;
  if own and coalesce(d -> 'stats' ->> 'lastDay', '') <> public.dc__day() then
    d := jsonb_set(d, '{stats,lastDay}', to_jsonb(public.dc__day()));
    d := public.dc__bump(d, 'days');
  end if;
  return jsonb_set(d, '{updated}', to_jsonb(now_ms));
end $$;

-- verrouille un profil (le crée si besoin pour le joueur lui-même)
create or replace function public.dc__lock(u uuid, create_it boolean default false) returns jsonb language plpgsql volatile as $$
declare d jsonb; em text;
begin
  select data into d from public.docs where path = 'players/' || u for update;
  if found then return public.dc__norm(d); end if;
  if not create_it then raise exception 'Joueur introuvable.'; end if;
  select email into em from auth.users where id = u;
  d := public.dc__norm(jsonb_build_object('pseudo', left(split_part(coalesce(em, ''), '@', 1), 20)));
  insert into public.docs (path, coll, data) values ('players/' || u, 'players', public.dc__stamp(d, false))
    on conflict (path) do nothing;
  select data into d from public.docs where path = 'players/' || u for update;
  return public.dc__norm(d);
end $$;

create or replace function public.dc__save(u uuid, d jsonb, own boolean default true) returns jsonb language plpgsql volatile as $$
begin
  d := public.dc__stamp(d, own);
  update public.docs set data = d, updated_at = now() where path = 'players/' || u;
  return d;
end $$;

-- verrouille plusieurs joueurs toujours dans le même ordre (évite les blocages croisés)
create or replace function public.dc__lock_many(us uuid[]) returns void language plpgsql volatile as $$
begin
  perform 1 from public.docs where path = any (select 'players/' || x from unnest(us) x) order by path for update;
end $$;

create or replace function public.dc__packinfo(d jsonb, now_ms bigint, out n int, out g int) language plpgsql immutable as $$
declare cfg jsonb := public.dc__cfg(); maxp int := (cfg ->> 'maxp')::int; per bigint := (cfg ->> 'per')::bigint; packs int := public.dc__int(d, 'packs');
begin
  if packs >= maxp then n := maxp; g := 0; return; end if;
  g := greatest(0, floor((now_ms - public.dc__int(d, 'packTs'))::numeric / per)::int);
  n := least(maxp, packs + g);
end $$;

create or replace function public.dc__mid() returns text language sql volatile as
$$ select to_hex(public.dc__now()) || substr(md5(gen_random_uuid()::text), 1, 8) $$;

create or replace function public.dc__market(mid text) returns jsonb language plpgsql volatile as $$
declare m jsonb;
begin
  select data into m from public.docs where path = 'market/' || mid for update;
  return m;   -- null si l'annonce n'existe plus
end $$;

-- ============================================================
--  Profil
-- ============================================================
create or replace function public.dc_init() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb;
begin
  d := public.dc__lock(u, true);
  d := public.dc__save(u, d, true);
  return jsonb_build_object('profile', d, 'admin', public.dc__is_admin(u));
end $$;

create or replace function public.dc_set_pseudo(p_v text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); v text := left(btrim(regexp_replace(coalesce(p_v, ''), '\s+', ' ', 'g')), 20);
  nx bigint := public.dc__int(d, 'pseudoTs') + (public.dc__cfg() ->> 'pseudoWait')::bigint;
begin
  if v = coalesce(d ->> 'pseudo', '') then raise exception 'C’est déjà votre pseudo.'; end if;
  if public.dc__int(d, 'pseudoTs') > 0 and nx > public.dc__now() then raise exception 'Vous ne pouvez pas encore changer de pseudo.'; end if;
  d := d || jsonb_build_object('pseudo', v, 'pseudoTs', public.dc__now());
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

create or replace function public.dc_set_avatar(p_id int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true);
begin
  if public.dc__count(d, p_id) < 1 then raise exception 'Ce Pokémon n’est plus dans votre collection.'; end if;
  return jsonb_build_object('profile', public.dc__save(u, jsonb_set(d, '{avatar}', to_jsonb(p_id))));
end $$;

create or replace function public.dc_toggle_fav(p_id int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); k text := p_id::text; on_ boolean;
begin
  if d -> 'fav' ? k then d := jsonb_set(d, '{fav}', (d -> 'fav') - k); on_ := false;
  else
    if public.dc__count(d, p_id) < 1 then raise exception 'Vous ne possédez pas cette carte.'; end if;
    d := jsonb_set(d, '{fav}', (d -> 'fav') || jsonb_build_object(k, 1)); on_ := true;
  end if;
  return jsonb_build_object('profile', public.dc__save(u, d), 'on', on_);
end $$;

create or replace function public.dc_set_titles(p_keys jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true);
begin
  if jsonb_typeof(p_keys) <> 'array' then raise exception 'Sélection de titres invalide.'; end if;
  if jsonb_array_length(p_keys) > (public.dc__cfg() ->> 'titleMax')::int then raise exception '3 titres au maximum.'; end if;
  return jsonb_build_object('profile', public.dc__save(u, jsonb_set(d, '{titles}', p_keys)));
end $$;

-- ============================================================
--  Boosters, défausse, évolutions
-- ============================================================
create or replace function public.dc_open(p_k int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  now_ms bigint := public.dc__now(); maxp int := (cfg ->> 'maxp')::int; per bigint := (cfg ->> 'per')::bigint;
  b int; i int; r int; x int; k int; id int; legend int; pk record; drawn jsonb := '[]'; pool jsonb;
begin
  if not (cfg -> 'openOpts' @> to_jsonb(p_k)) then raise exception 'Nombre de boosters invalide.'; end if;
  select * into pk from public.dc__packinfo(d, now_ms);
  if pk.n + public.dc__int(d, 'bonus') < p_k then
    raise exception '%', case when p_k > 1 then format('Il vous faut %s boosters disponibles pour en ouvrir %s d’un coup.', p_k, p_k)
      else 'Aucun booster disponible. Attendez le prochain ou passez par la boutique.' end;
  end if;
  for b in 1 .. p_k loop
    select * into pk from public.dc__packinfo(d, now_ms);
    if pk.n >= 1 then
      if pk.n >= maxp then d := d || jsonb_build_object('packs', maxp - 1, 'packTs', now_ms);
      else d := d || jsonb_build_object('packs', pk.n - 1, 'packTs', public.dc__int(d, 'packTs') + pk.g * per); end if;
    else d := jsonb_set(d, '{bonus}', to_jsonb(public.dc__int(d, 'bonus') - 1)); end if;
    legend := 0;
    for i in 1 .. (cfg ->> 'cards')::int loop
      x := public.dc__rnd((cfg ->> 'scale')::int); r := 0;
      for k in 0 .. 7 loop
        if x < (cfg -> 'oddsK' ->> k)::int then r := k; exit; end if;
        x := x - (cfg -> 'oddsK' ->> k)::int;
      end loop;
      pool := cfg -> 'byr' -> r;
      id := (pool ->> public.dc__rnd(jsonb_array_length(pool)))::int;
      drawn := drawn || jsonb_build_array(jsonb_build_object('id', id, 'isNew', public.dc__count(d, id) = 0));
      d := public.dc__add(d, id, 1);
      if r = 5 then legend := legend + 1; end if;
    end loop;
    d := public.dc__bump(d, 'packs');
    if legend >= 2 then d := jsonb_set(d, '{stats,luck}', '1'); end if;
  end loop;
  return jsonb_build_object('profile', public.dc__save(u, d), 'drawn', drawn);
end $$;

create or replace function public.dc_discard(p_sel jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); r record; q int; gained bigint := 0; n bigint := 0;
begin
  if jsonb_typeof(p_sel) <> 'object' then raise exception 'Sélection invalide.'; end if;
  for r in select key, value from jsonb_each(p_sel) loop
    q := (r.value #>> '{}')::int;
    if q is null or q < 1 then raise exception 'Sélection invalide.'; end if;
    if d -> 'fav' ? r.key then raise exception 'Une carte favorite est protégée de la défausse.'; end if;
    if public.dc__count(d, r.key::int) < q then raise exception 'Certaines cartes ne sont plus dans votre collection.'; end if;
    d := public.dc__add(d, r.key::int, -q);
    gained := gained + q * (cfg -> 'discard' ->> public.dc__rar(cfg, r.key::int))::int; n := n + q;
  end loop;
  if n = 0 then raise exception 'Aucune carte sélectionnée.'; end if;
  d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + gained));
  d := public.dc__bump(d, 'discards', n);
  return jsonb_build_object('profile', public.dc__save(u, d), 'gained', gained, 'n', n);
end $$;

create or replace function public.dc_evolve(p_from int, p_to int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); was_new boolean;
begin
  if not coalesce(cfg -> 'evo' -> p_from::text @> to_jsonb(p_to), false) then raise exception 'Évolution impossible.'; end if;
  if public.dc__count(d, p_from) < (cfg ->> 'evoCost')::int then raise exception 'Il vous faut % exemplaires pour faire évoluer ce Pokémon.', cfg ->> 'evoCost'; end if;
  was_new := public.dc__count(d, p_to) = 0;
  d := public.dc__add(public.dc__add(d, p_from, -(cfg ->> 'evoCost')::int), p_to, 1);
  d := public.dc__bump(d, 'evos');
  return jsonb_build_object('profile', public.dc__save(u, d), 'wasNew', was_new);
end $$;

-- Évolution rapide : Pokémon en 4 exemplaires ou plus dont une évolution manque encore
create or replace function public.dc_quick_evo() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  cost int := (cfg ->> 'evoCost')::int; r record; t jsonb; done jsonb := '[]'; guard int; target int;
begin
  for r in select key::int id from jsonb_each(d -> 'coll') where cfg -> 'evo' ? key
           order by (value #>> '{}')::int desc, key::int loop
    guard := 0;
    while public.dc__count(d, r.id) >= cost + 1 and guard < 60 loop
      guard := guard + 1; target := null;
      for t in select value from jsonb_array_elements(cfg -> 'evo' -> r.id::text) loop
        if public.dc__count(d, (t #>> '{}')::int) = 0 then target := (t #>> '{}')::int; exit; end if;
      end loop;
      exit when target is null;
      d := public.dc__add(public.dc__add(d, r.id, -cost), target, 1);
      d := public.dc__bump(d, 'evos'); done := done || to_jsonb(target);
    end loop;
  end loop;
  if jsonb_array_length(done) = 0 then raise exception 'Plus rien à faire évoluer.'; end if;
  return jsonb_build_object('profile', public.dc__save(u, d), 'done', done);
end $$;

-- ============================================================
--  Boutique
-- ============================================================
create or replace function public.dc_buy_packs(p_q int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  free_ boolean; cost bigint := p_q * (cfg ->> 'packPrice')::bigint;
begin
  if p_q not in (1, 5, 10) then raise exception 'Quantité invalide.'; end if;
  free_ := public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false);
  if not free_ then
    if public.dc__int(d, 'credits') < cost then raise exception 'Vous n’avez pas assez de crédits.'; end if;
    d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - cost));
  end if;
  d := jsonb_set(d, '{bonus}', to_jsonb(public.dc__int(d, 'bonus') + p_q));
  return jsonb_build_object('profile', public.dc__save(u, d), 'free', free_);
end $$;

create or replace function public.dc_buy_once(p_key text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); o jsonb := public.dc__cfg() -> 'once' -> p_key;
begin
  if o is null then raise exception 'Offre inconnue.'; end if;
  if d -> 'bought' ? p_key then raise exception 'Vous avez déjà récupéré cette offre.'; end if;
  if not ((o ->> 'free')::boolean or (public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false))) then
    raise exception 'Paiement indisponible pendant la bêta.';
  end if;
  d := jsonb_set(d, '{bought}', (d -> 'bought') || jsonb_build_object(p_key, public.dc__now()));
  d := d || jsonb_build_object('credits', public.dc__int(d, 'credits') + (o ->> 'credits')::bigint, 'bonus', public.dc__int(d, 'bonus') + (o ->> 'packs')::int);
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

-- ============================================================
--  Enchères
-- ============================================================
create or replace function public.dc_auction_create(p_card int, p_start bigint, p_hours numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); mid text := public.dc__mid(); now_ms bigint := public.dc__now(); n int;
begin
  if not (cfg -> 'aucHours' @> to_jsonb(p_hours)) then raise exception 'Durée invalide.'; end if;
  if p_start is null or p_start < 1 or p_start > 1000000000 then raise exception 'Le prix de départ doit être d’au moins 1 crédit.'; end if;
  select count(*) into n from public.docs where coll = 'market' and data ->> 'kind' = 'a' and data ->> 'seller' = u::text;
  if n >= (cfg ->> 'maxAuctions')::int then raise exception 'Vous avez déjà % cartes aux enchères.', cfg ->> 'maxAuctions'; end if;
  if public.dc__count(d, p_card) < 1 then raise exception 'Vous ne possédez plus cette carte.'; end if;
  d := public.dc__add(d, p_card, -1);
  insert into public.docs (path, coll, data) values ('market/' || mid, 'market', jsonb_build_object(
    'kind', 'a', 'seller', u, 'card', p_card, 'rarity', public.dc__rar(cfg, p_card), 'start', p_start, 'bid', 0, 'bidder', null,
    'created', now_ms, 'endsAt', now_ms + round(p_hours * 3600000)::bigint));
  return jsonb_build_object('profile', public.dc__save(u, d), 'mid', mid);
end $$;

create or replace function public.dc_bid(p_mid text, p_amount bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); d jsonb; o jsonb; prev uuid; mn bigint; need bigint;
begin
  if m is null or m ->> 'kind' <> 'a' then raise exception 'Cette enchère est terminée.'; end if;
  if m ->> 'seller' = u::text then raise exception 'Vous ne pouvez pas enchérir sur votre propre carte.'; end if;
  if public.dc__now() >= public.dc__int(m, 'endsAt') then raise exception 'Cette enchère est terminée.'; end if;
  prev := nullif(m ->> 'bidder', '')::uuid;
  mn := case when prev is null then public.dc__int(m, 'start') else public.dc__int(m, 'bid') + 1 end;
  if p_amount is null or p_amount < mn then raise exception 'L’offre minimale est de % crédits.', mn; end if;
  perform public.dc__lock_many(array_remove(array[u, prev], null));
  d := public.dc__lock(u, true);
  need := case when prev = u then p_amount - public.dc__int(m, 'bid') else p_amount end;
  if public.dc__int(d, 'credits') < need then raise exception 'Vous n’avez pas assez de crédits.'; end if;
  d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - need));
  if prev is not null and prev <> u then   -- l'enchérisseur dépassé est remboursé tout de suite
    o := public.dc__lock(prev);
    perform public.dc__save(prev, jsonb_set(o, '{credits}', to_jsonb(public.dc__int(o, 'credits') + public.dc__int(m, 'bid'))), false);
  end if;
  update public.docs set data = m || jsonb_build_object('bid', p_amount, 'bidder', u, 'lastBid', public.dc__now()), updated_at = now() where path = 'market/' || p_mid;
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

create or replace function public.dc_auction_cancel(p_mid text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); m jsonb := public.dc__market(p_mid); d jsonb;
begin
  if m is null then raise exception 'Cette annonce n’existe plus.'; end if;
  if m ->> 'seller' <> u::text then raise exception 'Cette annonce n’est pas la vôtre.'; end if;
  if m ->> 'bidder' is not null or public.dc__now() >= public.dc__int(m, 'endsAt') then raise exception 'Impossible d’annuler : l’enchère a déjà reçu une offre.'; end if;
  d := public.dc__lock(u, true);
  delete from public.docs where path = 'market/' || p_mid;
  return jsonb_build_object('profile', public.dc__save(u, public.dc__add(d, public.dc__int(m, 'card')::int, 1)));
end $$;

-- clôture d'une enchère terminée : n'importe quel joueur peut la déclencher, une seule fois
create or replace function public.dc_auction_settle(p_mid text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare m jsonb := public.dc__market(p_mid); s uuid; b uuid; ds jsonb; db_ jsonb;
begin
  perform public.dc__uid();
  if m is null or m ->> 'kind' <> 'a' or public.dc__now() < public.dc__int(m, 'endsAt') then return false; end if;
  s := (m ->> 'seller')::uuid; b := nullif(m ->> 'bidder', '')::uuid;
  perform public.dc__lock_many(array_remove(array[s, b], null));
  ds := public.dc__lock(s);
  if b is null then
    perform public.dc__save(s, public.dc__add(ds, public.dc__int(m, 'card')::int, 1), false);
  else
    db_ := public.dc__lock(b);
    ds := public.dc__bump(jsonb_set(ds, '{credits}', to_jsonb(public.dc__int(ds, 'credits') + public.dc__int(m, 'bid'))), 'aucSold');
    perform public.dc__save(s, ds, false);
    perform public.dc__save(b, public.dc__bump(public.dc__add(db_, public.dc__int(m, 'card')::int, 1), 'aucWon'), false);
  end if;
  delete from public.docs where path = 'market/' || p_mid;
  return true;
end $$;

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
    if public.dc__count(ow, p_card) > 0 then raise exception 'Le propriétaire possède déjà cette carte.'; end if;
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
  return jsonb_build_object('profile', public.dc__save(u, d));
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
  select array_agg(distinct (value ->> 'by')::uuid) into us from jsonb_each(m -> 'offers') where value ->> 'status' = 'pending';
  perform public.dc__lock_many(us || u);
  perform public.dc__return_offers(m, p_oid);
  p := public.dc__lock(by_);
  perform public.dc__save(by_, public.dc__bump(public.dc__add(p, public.dc__int(m, 'card')::int, 1), 'trades'), false);
  d := public.dc__lock(u, true);
  d := public.dc__bump(public.dc__add(d, public.dc__int(o, 'card')::int, 1), 'trades');
  delete from public.docs where path = 'market/' || p_mid;
  return jsonb_build_object('profile', public.dc__save(u, d), 'accepted', true, 'card', o -> 'card');
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
declare a uuid := public.dc__admin(); d jsonb := public.dc__lock(p_uid, p_uid = a);
begin
  d := d || jsonb_build_object('credits', greatest(0, public.dc__int(d, 'credits') + coalesce(p_cr, 0)), 'bonus', greatest(0, public.dc__int(d, 'bonus') + coalesce(p_pk, 0)));
  d := public.dc__save(p_uid, d, p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end);
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
  d := public.dc__save(p_uid, jsonb_set(d, '{pseudo}', to_jsonb(left(btrim(regexp_replace(coalesce(p_v, ''), '\s+', ' ', 'g')), 20))), p_uid = a);
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
  if not p_full then keep := keep || jsonb_build_object('pseudo', d -> 'pseudo', 'pseudoTs', d -> 'pseudoTs'); end if;
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
      'alpha', p.data -> 'alpha', 'beta', p.data -> 'beta', 'dev', p.data -> 'dev')), false), updated_at = now() where path = p.path;
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
--  Droits d'exécution : seules les fonctions dc_* sont appelables par les joueurs connectés
-- ============================================================
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'dc\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname not like 'dc\_\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;

select 'serveur DexCraft 0.4.0 OK' as verif, count(*) as fonctions from pg_proc where proname like 'dc\_%';
