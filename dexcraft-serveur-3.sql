-- ============================================================
--  DexCraft — serveur, PARTIE 3 / 3 : codes cadeaux, historique des échanges, récompense quotidienne, don de cartes, suppression des comptes
--  À coller dans Supabase > SQL Editor > Run, APRÈS dexcraft-serveur.sql et dexcraft-serveur-2.sql.
--  Relançable sans risque.
-- ============================================================

-- ---------- codes cadeaux ----------
create table if not exists public.promo_codes (
  code     text primary key,               -- en majuscules
  credits  bigint not null default 0,
  packs    int not null default 0,         -- boosters ajoutés à la réserve achetée (bonus)
  active   boolean not null default true,
  max_uses int,                            -- nombre total d'utilisations (tous joueurs), null = illimité
  uses     int not null default 0
);
create table if not exists public.promo_redemptions (   -- un code ne sert qu'une fois par joueur
  code text not null references public.promo_codes(code) on delete cascade,
  uid  uuid not null,
  at   timestamptz not null default now(),
  primary key (code, uid)
);
alter table public.promo_codes enable row level security;
alter table public.promo_redemptions enable row level security;
-- essais de codes (0.8.7) : 10 codes inconnus par heure et par joueur au plus, pour qu'un script ne puisse pas deviner les codes
create table if not exists public.promo_tries (uid uuid primary key, hour bigint not null, n int not null default 0);
alter table public.promo_tries enable row level security;
revoke all on public.promo_codes, public.promo_redemptions, public.promo_tries from anon, authenticated;

-- Les codes se créent directement dans l'éditeur SQL de Supabase, JAMAIS dans un fichier du dépôt :
-- le dépôt GitHub est public, un code écrit ici serait lisible par tous avant son annonce.

create or replace function public.dc_redeem_code(p_code text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); c public.promo_codes; d jsonb; k text := upper(btrim(coalesce(p_code, '')));
  h bigint := floor(extract(epoch from now()) / 3600); t int;
begin
  if k = '' then raise exception 'Entrez un code.'; end if;
  select case when hour = h then n else 0 end into t from public.promo_tries where uid = u;
  if coalesce(t, 0) >= 10 then raise exception 'Trop de codes essayés : réessayez dans une heure.'; end if;
  select * into c from public.promo_codes where code = k for update;
  if not found or not c.active then
    -- l'essai raté est compté puis enregistré : pas d'exception ici, elle annulerait le compteur
    insert into public.promo_tries (uid, hour, n) values (u, h, 1) on conflict (uid) do update
      set n = case when promo_tries.hour = h then promo_tries.n + 1 else 1 end, hour = h;
    return jsonb_build_object('error', 'Ce code n’existe pas ou n’est plus valable.');
  end if;
  if c.max_uses is not null and c.uses >= c.max_uses then raise exception 'Ce code a déjà été utilisé.'; end if;
  if exists (select 1 from public.promo_redemptions where code = k and uid = u) then raise exception 'Vous avez déjà utilisé ce code.'; end if;
  d := public.dc__lock(u, true);
  insert into public.promo_redemptions (code, uid) values (k, u);
  update public.promo_codes set uses = uses + 1 where code = k;
  d := d || jsonb_build_object('credits', public.dc__int(d, 'credits') + c.credits, 'bonus', public.dc__int(d, 'bonus') + c.packs);
  return jsonb_build_object('profile', public.dc__save(u, d), 'code', k, 'credits', c.credits, 'packs', c.packs);
end $$;

-- ---------- cartes secrètes (0.8.7) ----------
-- Les données des mythiques et transcendantes ne sont plus dans index.html (lisible par tous) : table secret_cards,
-- remplie par secret/cartes-secretes.sql (généré sur le PC de Theo, jamais publié). Les joueurs n'y ont pas accès ;
-- dc_secret_cards leur envoie la liste des numéros (titres, tableaux par rareté) et les données des seules cartes
-- qu'ils ont le droit de voir : possédées, dans leur boîte cadeau, image de profil d'un joueur, sur le marché
-- (annonce ou proposition), dans leur historique d'échanges. L'administrateur reçoit tout.
create table if not exists public.secret_cards (id int primary key, data jsonb not null);
alter table public.secret_cards enable row level security;
revoke all on public.secret_cards from anon, authenticated;
create index if not exists docs_player_avatar_idx on public.docs ((data ->> 'avatar')) where coll = 'players';
create index if not exists docs_market_card_idx on public.docs ((data ->> 'card')) where coll = 'market';

create or replace function public.dc_secret_cards(p_ids int[]) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb; ok int[] := '{}'; i int; k text;
begin
  if u is null then raise exception 'Connectez-vous pour jouer.'; end if;
  if public.dc__is_admin(u) then ok := array(select id from public.secret_cards);
  else
    select data into d from public.docs where path = 'players/' || u;
    foreach i in array coalesce(p_ids[1:100], '{}') loop
      k := i::text;
      if not exists (select 1 from public.secret_cards where id = i) then continue; end if;
      if public.dc__count(coalesce(d, '{}'), i) > 0
        or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(d -> 'gifts') = 'array' then d -> 'gifts' else '[]' end) g where g ->> 'c' = k)
        or exists (select 1 from public.docs where coll = 'players' and data ->> 'avatar' = k)
        or exists (select 1 from public.docs where coll = 'market' and data ->> 'card' = k)
        or exists (select 1 from public.docs m, jsonb_each(case when jsonb_typeof(m.data -> 'offers') = 'object' then m.data -> 'offers' else '{}' end) o
                   where m.coll = 'market' and o.value ->> 'card' = k)
        or exists (select 1 from public.trade_log where (owner = u or taker = u) and (owner_card = i or taker_card = i))
      then ok := ok || i; end if;
    end loop;
  end if;
  return jsonb_build_object(
    'ids', jsonb_build_object(
      '6', coalesce((select jsonb_agg(id order by id) from public.secret_cards where (data ->> 7)::int = 6), '[]'),
      '7', coalesce((select jsonb_agg(id order by id) from public.secret_cards where (data ->> 7)::int = 7), '[]')),
    'cards', coalesce((select jsonb_object_agg(id::text, data) from public.secret_cards where id = any(ok)), '{}'));
end $$;

-- ---------- historique des échanges (0.6.0) ----------
-- Une ligne par échange conclu, écrite par dc_trade_answer. Chaque joueur ne lit que ses propres échanges.
create table if not exists public.trade_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  owner      uuid not null,      -- propriétaire de l'annonce
  owner_card int not null,       -- carte qu'il a donnée
  taker      uuid not null,      -- joueur dont la proposition a été acceptée
  taker_card int not null        -- carte qu'il a donnée
);
create index if not exists trade_log_owner_idx on public.trade_log (owner, at desc);
create index if not exists trade_log_taker_idx on public.trade_log (taker, at desc);
alter table public.trade_log enable row level security;
revoke all on public.trade_log from anon, authenticated;
grant select on public.trade_log to authenticated;
drop policy if exists trade_log_read on public.trade_log;
create policy trade_log_read on public.trade_log for select to authenticated using (auth.uid() = owner or auth.uid() = taker);

-- ---------- plusieurs annonces d'échange en un seul appel (0.6.4) ----------
-- Depuis la collection (« Mettre à l'échange ») : une annonce par carte, un exemplaire chacune, tout dans
-- une seule transaction (rapide, et impossible de lancer deux fois la même liste en parallèle : le profil est verrouillé).
-- Les cartes que le joueur ne possède plus sont ignorées et renvoyées dans « skipped ».
drop function if exists public.dc_trade_create_many(integer[], text);   -- remplacée par la version avec p_auto (0.7.1)
create or replace function public.dc_trade_create_many(p_cards int[], p_mode text, p_auto boolean default false) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); c int; n int := 0; skipped int[] := '{}';
  room int := public.dc__listing_cap() - public.dc__open_listings(u); capped int := 0;
begin
  if coalesce(array_length(p_cards, 1), 0) = 0 then raise exception 'Aucune carte choisie.'; end if;
  if array_length(p_cards, 1) > 500 then raise exception 'Trop de cartes d’un coup : 500 au maximum.'; end if;
  if room <= 0 then raise exception 'Vous avez déjà % annonces d’échange : c’est le maximum. Retirez-en avant d’en publier d’autres.', public.dc__listing_cap(); end if;
  for c in select distinct x from unnest(p_cards) x where x is not null loop
    if public.dc__rar(cfg, c) is null or public.dc__count(d, c) < 1 then skipped := skipped || c; continue; end if;
    if n >= room then capped := capped + 1; continue; end if;  -- plafond d'annonces atteint
    d := public.dc__add(d, c, -1);
    insert into public.docs (path, coll, data) values ('market/' || public.dc__mid(), 'market', jsonb_build_object(
      'kind', 't', 'owner', u, 'card', c, 'rarity', public.dc__rar(cfg, c), 'want', null,
      'wantMode', case when p_mode = 'missing' then 'missing' end,
      'status', 'open', 'offers', '{}'::jsonb, 'created', public.dc__now(), 'auto', coalesce(p_auto, false)));
    n := n + 1;
  end loop;
  return jsonb_build_object('profile', public.dc__save(u, d), 'n', n, 'skipped', to_jsonb(skipped), 'capped', capped);
end $$;

-- ---------- gestion groupée de ses annonces d'échange (0.6.9) ----------
-- p_action = 'cancel' : retire les annonces (cartes rendues au propriétaire, propositions rendues à leurs auteurs) ;
-- p_action = 'mode'   : change la demande (p_mode 'missing' = carte qui me manque, sinon n'importe quelle carte de même rareté).
-- Seules les annonces du joueur sont touchées ; les autres identifiants sont ignorés.
create or replace function public.dc_trade_bulk(p_mids text[], p_action text, p_mode text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb; m record; us uuid[]; n int := 0; oid text; acc int := 0;
begin
  if coalesce(array_length(p_mids, 1), 0) = 0 then raise exception 'Aucune annonce choisie.'; end if;
  if array_length(p_mids, 1) > 500 then raise exception 'Trop d’annonces d’un coup : 500 au maximum.'; end if;
  if p_action not in ('cancel', 'mode', 'auto') then raise exception 'Action inconnue.'; end if;
  if p_action = 'cancel' then
    -- verrouille d'abord tous les joueurs concernés, toujours dans le même ordre
    select array_agg(distinct (o.value ->> 'by')::uuid) into us
      from public.docs x, jsonb_each(x.data -> 'offers') o
      where x.path = any (select 'market/' || y from unnest(p_mids) y) and x.data ->> 'owner' = u::text and o.value ->> 'status' = 'pending';
    perform public.dc__lock_many(coalesce(us, '{}') || u);
  end if;
  d := public.dc__lock(u, true);
  for m in select path, data from public.docs
           where path = any (select 'market/' || y from unnest(p_mids) y) and coll = 'market'
             and data ->> 'kind' = 't' and data ->> 'owner' = u::text for update loop
    if p_action = 'cancel' then
      perform public.dc__return_offers(m.data, null);
      d := public.dc__add(d, public.dc__int(m.data, 'card')::int, 1);
      delete from public.docs where path = m.path;
    elsif p_action = 'auto' then
      -- acceptation automatique (0.7.1) : la première proposition valide est acceptée d'office ;
      -- en l'activant, la plus ancienne proposition déjà en attente est acceptée tout de suite
      update public.docs set data = m.data || jsonb_build_object('auto', p_mode = 'on'), updated_at = now() where path = m.path;
      if p_mode = 'on' then
        select key into oid from jsonb_each(m.data -> 'offers') where value ->> 'status' = 'pending' order by (value ->> 'at')::bigint limit 1;
        if oid is not null then perform public.dc__trade_accept(substr(m.path, 8), oid); acc := acc + 1; end if;
      end if;
    else
      update public.docs set data = m.data || jsonb_build_object('want', null, 'wantMode', case when p_mode = 'missing' then 'missing' end), updated_at = now()
        where path = m.path;
    end if;
    n := n + 1;
  end loop;
  if p_action = 'auto' then d := public.dc__lock(u, true); end if;   -- relu : les échanges conclus ont modifié le profil
  return jsonb_build_object('profile', public.dc__save(u, d), 'n', n, 'accepted', acc);
end $$;

-- ---------- bulles d'aide des nouveaux joueurs (0.7.0) ----------
-- Une bulle fermée, ou dont l'action a été faite, ne revient jamais (tips dans le profil, sur tous les appareils).
-- Cartes recherchées (0.8.6) : la cloche d'une carte manquante. Le joueur est prévenu quand elle arrive sur le marché.
-- Seulement les cartes du Pokédex (jamais une mythique ou une transcendante), 300 au plus ; retirées par dc__stamp
-- dès que la carte entre dans la collection.
create or replace function public.dc_toggle_wish(p_id int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); k text := p_id::text; w jsonb; on_ boolean;
begin
  if not coalesce(cfg -> 'dexOrder' @> to_jsonb(p_id), false) then raise exception 'Carte inconnue.'; end if;
  w := case when jsonb_typeof(d -> 'wish') = 'object' then d -> 'wish' else '{}'::jsonb end;
  if w ? k then w := w - k; on_ := false;
  else
    if public.dc__count(d, p_id) > 0 then raise exception 'Vous avez déjà cette carte.'; end if;
    if (select count(*) from jsonb_object_keys(w)) >= 300 then raise exception 'Vous recherchez déjà 300 cartes : retirez-en une d’abord.'; end if;
    w := w || jsonb_build_object(k, public.dc__now()); on_ := true;
  end if;
  d := jsonb_set(d, '{wish}', w);
  return jsonb_build_object('profile', public.dc__save(u, d), 'on', on_);
end $$;

create or replace function public.dc_tip_done(p_key text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true);
begin
  if p_key not in ('booster', 'daily', 'collection', 'trades') then raise exception 'Bulle d’aide inconnue.'; end if;
  d := jsonb_set(d, '{tips}', (case when jsonb_typeof(d -> 'tips') = 'object' then d -> 'tips' else '{}' end) || jsonb_build_object(p_key, true));
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

-- ---------- récompense de connexion quotidienne (0.6.0) ----------
-- Une fois par jour (heure de Paris). Série de 7 jours (daily.streak), qui repart à 1 si un jour est manqué
-- et recommence après le 7e. Les récompenses sont dans la configuration (cfg.daily).
create or replace function public.dc_daily_claim() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  today text := public.dc__day(); yest text := to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD');
  last text := coalesce(d -> 'daily' ->> 'day', ''); st int := coalesce((d -> 'daily' ->> 'streak')::int, 0); rw jsonb;
begin
  if last = today then raise exception 'Récompense du jour déjà récupérée. Revenez demain !'; end if;
  st := case when last = yest then st % jsonb_array_length(cfg -> 'daily') + 1 else 1 end;
  rw := cfg -> 'daily' -> (st - 1);
  d := d || jsonb_build_object('daily', jsonb_build_object('day', today, 'streak', st),
    'credits', public.dc__int(d, 'credits') + coalesce((rw ->> 'credits')::bigint, 0),
    'bonus', public.dc__int(d, 'bonus') + coalesce((rw ->> 'packs')::int, 0));
  return jsonb_build_object('profile', public.dc__save(u, d), 'streak', st, 'credits', coalesce((rw ->> 'credits')::bigint, 0), 'packs', coalesce((rw ->> 'packs')::int, 0));
end $$;

-- ---------- administrateur : donner (ou retirer) n'importe quelle carte à un joueur ----------
create or replace function public.dc_admin_give_card(p_uid uuid, p_card int, p_n int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb; n int; g jsonb;
begin
  if p_card is null or not (public.dc__cfg() -> 'rar' ? p_card::text) then raise exception 'Cette carte n’existe pas.'; end if;
  if p_n is null or p_n = 0 or abs(p_n) > 1000 then raise exception 'Indiquez un nombre d’exemplaires entre 1 et 1 000 (négatif pour en retirer).'; end if;
  d := public.dc__lock(p_uid, p_uid = a);
  if p_n > 0 then
    -- don : la carte attend dans la boîte cadeau du joueur (gifts), il la découvre en l'ouvrant (dc_gift_open)
    g := case when jsonb_typeof(d -> 'gifts') = 'array' then d -> 'gifts' else '[]' end;
    d := jsonb_set(d, '{gifts}', g || jsonb_build_array(jsonb_build_object('c', p_card, 'n', p_n)));
    n := p_n;
  else
    n := greatest(p_n, -public.dc__count(d, p_card));        -- on ne retire jamais plus qu'il n'en possède
    if n = 0 then raise exception 'Ce joueur ne possède pas cette carte.'; end if;
    d := public.dc__add(d, p_card, n);
  end if;
  d := public.dc__save(p_uid, d, p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end, 'n', n, 'gift', p_n > 0);
end $$;

-- ---------- boîte cadeau (0.6.8) ----------
-- Le joueur ouvre ses cadeaux : crédits et boosters versés ; les cartes passent dans sa collection et sont renvoyées pour être retournées
-- une à une comme un booster (50 cartes affichées au plus, les suivantes sont ajoutées sans animation).
create or replace function public.dc_gift_open() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); g record; k int;
  shown jsonb := '[]'; nshown int := 0; total int := 0; cr bigint := 0; pk int := 0;
begin
  if coalesce(jsonb_typeof(d -> 'gifts'), '') <> 'array' or jsonb_array_length(d -> 'gifts') = 0 then raise exception 'Aucun cadeau à ouvrir.'; end if;
  for g in select (x ->> 'c')::int as c, greatest(coalesce((x ->> 'n')::int, 1), 1) as n,
                  greatest(coalesce((x ->> 'cr')::bigint, 0), 0) as cr, greatest(coalesce((x ->> 'pk')::int, 0), 0) as pk
           from jsonb_array_elements(d -> 'gifts') x loop
    cr := cr + g.cr; pk := pk + g.pk;                              -- crédits et boosters offerts
    if g.c is null or public.dc__rar(cfg, g.c) is null then continue; end if;
    for k in 1 .. g.n loop                                         -- cartes offertes
      if nshown < 50 then
        shown := shown || jsonb_build_array(jsonb_build_object('id', g.c, 'isNew', public.dc__count(d, g.c) = 0));
        nshown := nshown + 1;
      end if;
      d := public.dc__add(d, g.c, 1); total := total + 1;
    end loop;
  end loop;
  d := (d - 'gifts') || jsonb_build_object('credits', public.dc__int(d, 'credits') + cr, 'bonus', public.dc__int(d, 'bonus') + pk);
  return jsonb_build_object('profile', public.dc__save(u, d), 'drawn', shown, 'total', total, 'credits', cr, 'packs', pk);
end $$;

-- ---------- suppression d'un joueur ----------
-- Efface son profil, sa partie de VoltoBataille et ses annonces, en rendant aux autres ce qui leur revient.
create or replace function public.dc__purge_player(u uuid) returns void language plpgsql volatile as $$
declare m record; o jsonb; k text;
begin
  for m in select path, data from public.docs where coll = 'market' for update loop
    if m.data ->> 'kind' = 'a' and m.data ->> 'seller' = u::text then           -- sa vente : l'enchérisseur est remboursé
      if m.data ->> 'bidder' is not null and exists (select 1 from public.docs where path = 'players/' || (m.data ->> 'bidder')) then
        o := public.dc__lock((m.data ->> 'bidder')::uuid);
        perform public.dc__save((m.data ->> 'bidder')::uuid, jsonb_set(o, '{credits}', to_jsonb(public.dc__int(o, 'credits') + public.dc__int(m.data, 'bid'))), false);
      end if;
      delete from public.docs where path = m.path;
    elsif m.data ->> 'kind' = 'a' and m.data ->> 'bidder' = u::text then        -- sa mise : l'enchère repart sans offre
      update public.docs set data = m.data || jsonb_build_object('bid', 0, 'bidder', null), updated_at = now() where path = m.path;
    elsif m.data ->> 'kind' = 't' and m.data ->> 'owner' = u::text then         -- son échange : les propositions sont rendues
      perform public.dc__return_offers(m.data, null);
      delete from public.docs where path = m.path;
    elsif m.data ->> 'kind' = 't' then                                           -- ses propositions chez les autres : retirées
      for k in select key from jsonb_each(m.data -> 'offers') where value ->> 'by' = u::text loop
        update public.docs set data = jsonb_set(data, '{offers}', (data -> 'offers') - k), updated_at = now() where path = m.path;
      end loop;
    end if;
  end loop;
  delete from public.vb_rounds where uid = u;
  delete from public.promo_redemptions where uid = u;
  delete from public.admins where uid = u;
  delete from public.docs where path = 'players/' || u;
end $$;

-- automatique : supprimer un compte (Authentication > Users > Delete user) supprime aussi son profil de jeu
create or replace function public.dc__on_user_deleted() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.dc__purge_player(old.id);
  return old;
end $$;
drop trigger if exists dc_user_deleted on auth.users;
create trigger dc_user_deleted after delete on auth.users for each row execute function public.dc__on_user_deleted();

-- nettoyage des profils dont le compte a déjà été supprimé
do $$
declare p record; n int := 0;
begin
  for p in select path from public.docs where coll = 'players'
           and not exists (select 1 from auth.users u where 'players/' || u.id = path) loop
    perform public.dc__purge_player(substr(p.path, 9)::uuid); n := n + 1;
  end loop;
  raise notice 'Profils orphelins supprimés : %', n;
end $$;

-- ---------- droits d'exécution ----------
revoke all on function public.dc_secret_cards(integer[]) from public, anon;
grant execute on function public.dc_secret_cards(integer[]) to authenticated;
revoke all on function public.dc_redeem_code(text) from public, anon;
grant execute on function public.dc_redeem_code(text) to authenticated;
revoke all on function public.dc_admin_give_card(uuid,integer,integer) from public, anon;
grant execute on function public.dc_admin_give_card(uuid,integer,integer) to authenticated;
revoke all on function public.dc_gift_open() from public, anon;
grant execute on function public.dc_gift_open() to authenticated;
revoke all on function public.dc_toggle_wish(integer) from public, anon;
grant execute on function public.dc_toggle_wish(integer) to authenticated;
revoke all on function public.dc_tip_done(text) from public, anon;
grant execute on function public.dc_tip_done(text) to authenticated;
revoke all on function public.dc_trade_bulk(text[],text,text) from public, anon;
grant execute on function public.dc_trade_bulk(text[],text,text) to authenticated;
revoke all on function public.dc_daily_claim() from public, anon;
grant execute on function public.dc_daily_claim() to authenticated;
revoke all on function public.dc_trade_create_many(integer[],text,boolean) from public, anon;
grant execute on function public.dc_trade_create_many(integer[],text,boolean) to authenticated;
revoke all on function public.dc__purge_player(uuid) from public, anon, authenticated;
revoke all on function public.dc__on_user_deleted() from public, anon, authenticated;

-- fonctions internes : chemin de recherche fixé (avertissement « Function Search Path Mutable » de Supabase)
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'dc\_%' and p.proconfig is null loop
    execute format('alter function %s set search_path = public, extensions', f);
  end loop;
end $$;

select 'serveur DexCraft partie 3 OK' as verif,
  (select count(*) from public.docs where coll = 'players') as joueurs,
  (select count(*) from public.promo_codes) as codes;
