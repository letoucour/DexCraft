-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 4 (1.2.3) : boosters spéciaux (inventaire depuis la 1.2.5) ; marché lu par morceaux (1.3.12).
--  À lancer après dexcraft-serveur.sql, dexcraft-serveur-2.sql et dexcraft-serveur-3.sql (et la configuration).
-- ============================================================

-- Tirage de p_k boosters spéciaux dans le profil d, sans l'enregistrer. Renvoie {d, drawn}.
--   'gen'  : 5 cartes de la génération p_val (1 à 9) ;
--   'type' : 5 cartes du type p_val (1 à 18) ;
--   'prem' : 5 cartes Rare ou mieux (chances premK : celles d'un booster normal réparties sur les raretés Rare et plus, depuis la 1.2.4).
-- Génération et Type : même tirage de rareté qu'un booster normal (oddsK), Pokémon pris seulement dans le choix
-- (cfg.spCard : génération et types de chaque carte de dexOrder), jamais de mythique ni de transcendante ; une rareté
-- sans aucune carte du choix est retirée du tirage, pour que le booster respecte toujours ce qui a été acheté.
create or replace function public.dc__open_special(d jsonb, cfg jsonb, p_kind text, p_val int, p_k int) returns jsonb language plpgsql volatile as $$
declare now_ms bigint := public.dc__now(); sc text := cfg ->> 'spCard'; lst jsonb; pools jsonb := '[]'; pool jsonb;
  odds bigint[] := '{}'; tot bigint := 0; b int; i int; r int; x bigint; id int; sh boolean; drawn jsonb := '[]'; legend int;
begin
  if p_kind = 'gen' and p_val between 1 and 9 then
    select coalesce(jsonb_agg(v), '[]') into lst from jsonb_array_elements(cfg -> 'dexOrder') with ordinality as t(v, n)
      where substr(sc, 3 * n::int - 2, 1) = p_val::text;
  elsif p_kind = 'type' and p_val between 1 and 18 then
    select coalesce(jsonb_agg(v), '[]') into lst from jsonb_array_elements(cfg -> 'dexOrder') with ordinality as t(v, n)
      where chr(96 + p_val) in (substr(sc, 3 * n::int - 1, 1), substr(sc, 3 * n::int, 1));
  elsif p_kind <> 'prem' then raise exception 'Booster inconnu.';
  end if;
  if sc is null and p_kind <> 'prem' then raise exception 'Configuration du jeu à mettre à jour.'; end if;
  for r in 0 .. 7 loop
    pool := coalesce(cfg -> 'pool' -> (r::text), cfg -> 'byr' -> r);
    if lst is not null then
      pool := case when r >= 6 then '[]'::jsonb
        else (select coalesce(jsonb_agg(v), '[]') from jsonb_array_elements(pool) v where lst @> v) end;
    end if;
    pools := pools || jsonb_build_array(pool);
    odds := odds || case when jsonb_array_length(pool) = 0 then 0::bigint
      else ((case when p_kind = 'prem' then cfg -> 'premK' else cfg -> 'oddsK' end) ->> r)::bigint end;
    tot := tot + odds[r + 1];
  end loop;
  if tot = 0 then raise exception 'Booster inconnu.'; end if;
  for b in 1 .. p_k loop
    legend := 0;
    for i in 1 .. (cfg ->> 'cards')::int loop
      x := public.dc__rnd(tot::int); r := 0;
      for k in 0 .. 7 loop
        if x < odds[k + 1] then r := k; exit; end if;
        x := x - odds[k + 1];
      end loop;
      pool := pools -> r;
      id := (pool ->> public.dc__rnd(jsonb_array_length(pool)))::int;
      -- shiny : même règle que dc_open
      sh := false;
      if r <= 5 and cfg ? 'shinyBase' and not (cfg -> 'shinyNo' @> to_jsonb(id)) and not (d -> 'shiny' ? id::text) then
        sh := public.dc__rnd((cfg ->> 'shinyBase')::int) < 1 + least(coalesce((d -> 'got' ->> id::text)::int, 0), (cfg ->> 'shinyMax')::int - 1);
      end if;
      if sh then d := jsonb_set(d, '{shiny}', (d -> 'shiny') || jsonb_build_object(id::text, now_ms)); end if;
      drawn := drawn || jsonb_build_array(jsonb_build_object('id', id, 'isNew', public.dc__count(d, id) = 0)
        || case when sh then '{"shiny": true}'::jsonb else '{}'::jsonb end);
      d := public.dc__gain(d, id, 1);
      if r = 5 then legend := legend + 1; end if;
    end loop;
    d := public.dc__bump(d, 'packs');
    if legend >= 2 then d := jsonb_set(d, '{stats,luck}', '1'); end if;
  end loop;
  return jsonb_build_object('d', d, 'drawn', drawn);
end $$;

-- Inventaire des boosters spéciaux (1.2.5) : profil spInv = {"prem": n, "gen:3": n, "type:10": n}. Clé d'un booster, ou erreur.
create or replace function public.dc__sp_key(cfg jsonb, p_kind text, p_val int) returns text language plpgsql immutable as $$
begin
  if (cfg -> 'spb' -> p_kind) is null or (p_kind = 'gen' and not coalesce(p_val between 1 and 9, false))
     or (p_kind = 'type' and not coalesce(p_val between 1 and 18, false)) then raise exception 'Booster inconnu.'; end if;
  return case when p_kind = 'prem' then 'prem' else p_kind || ':' || p_val end;
end $$;

-- Achat en crédits : les boosters vont dans l'inventaire, ouverts plus tard depuis l'écran des boosters
-- (gratuit pour l'administrateur en mode développeur, comme dc_buy_packs).
create or replace function public.dc_buy_special(p_kind text, p_val int, p_q int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); k text := public.dc__sp_key(cfg, p_kind, p_val);
  cost bigint := (cfg -> 'spb' -> p_kind ->> 'price')::bigint * p_q; free_ boolean; inv jsonb;
begin
  if not (cfg -> 'openOpts' @> to_jsonb(p_q)) then raise exception 'Quantité invalide.'; end if;
  free_ := public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false);
  if not free_ then
    if public.dc__int(d, 'credits') < cost then raise exception 'Vous n’avez pas assez de crédits.'; end if;
    d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - cost));
  end if;
  inv := case when jsonb_typeof(d -> 'spInv') = 'object' then d -> 'spInv' else '{}' end;
  d := d || jsonb_build_object('spInv', inv || jsonb_build_object(k, coalesce((inv ->> k)::int, 0) + p_q));
  return jsonb_build_object('profile', public.dc__save(u, d), 'free', free_);
end $$;

-- Ouverture de 1 à 10 boosters de l'inventaire.
create or replace function public.dc_open_special(p_kind text, p_val int, p_k int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); k text := public.dc__sp_key(cfg, p_kind, p_val);
  o jsonb; now_ms bigint := public.dc__now(); inv jsonb; n int;
begin
  if p_k is null or p_k < 1 or p_k > 10 then raise exception 'Nombre de boosters invalide.'; end if;
  inv := case when jsonb_typeof(d -> 'spInv') = 'object' then d -> 'spInv' else '{}' end;
  n := coalesce((inv ->> k)::int, 0);
  if n < p_k then raise exception '%', case when n = 0 then 'Vous n’avez plus ce booster.' else format('Il ne vous reste que %s boosters de ce genre.', n) end; end if;
  d := d || jsonb_build_object('spInv', case when n = p_k then inv - k else inv || jsonb_build_object(k, n - p_k) end);
  o := public.dc__open_special(d, cfg, p_kind, p_val, p_k); d := o -> 'd';
  -- comme dc_open : dernier tirage (réponse perdue) et 50 dernières cartes tirées
  d := d || jsonb_build_object('lastOpen', jsonb_build_object('t', now_ms, 'drawn', o -> 'drawn'),
    'recent', (select jsonb_agg(v order by x.n) from jsonb_array_elements((o -> 'drawn') || coalesce(d -> 'recent', '[]'))
      with ordinality as x(v, n) where x.n <= 50));
  return jsonb_build_object('profile', public.dc__save(u, d), 'drawn', o -> 'drawn');
end $$;

-- Outil administrateur : boosters de toutes sortes dans la boîte cadeau d'un joueur.
-- 'pk' : boosters normaux (vont dans sa réserve à l'ouverture) ; 'gen', 'type', 'prem' : dans son inventaire à l'ouverture (dc_gift_open).
create or replace function public.dc_admin_give_booster(p_uid uuid, p_kind text, p_val int, p_n int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.dc__admin(); d jsonb; cfg jsonb := public.dc__cfg();
begin
  if p_n is null or p_n < 1 or p_n > 100 then raise exception 'Indiquez un nombre de boosters entre 1 et 100.'; end if;
  if p_kind <> 'pk' and (cfg -> 'spb' -> p_kind) is null then raise exception 'Booster inconnu.'; end if;
  if (p_kind = 'gen' and not coalesce(p_val between 1 and 9, false)) or (p_kind = 'type' and not coalesce(p_val between 1 and 18, false)) then
    raise exception 'Booster inconnu.'; end if;
  d := public.dc__lock(p_uid, p_uid = a);
  d := jsonb_set(d, '{gifts}', case when jsonb_typeof(d -> 'gifts') = 'array' then d -> 'gifts' else '[]' end
    || jsonb_build_array(case when p_kind = 'pk' then jsonb_build_object('pk', p_n)
                              else jsonb_build_object('sp', p_kind, 'v', coalesce(p_val, 0), 'n', p_n) end));
  d := public.dc__save(p_uid, d, p_uid = a);
  return jsonb_build_object('profile', case when p_uid = a then d end);
end $$;

-- ============================================================
--  Marché sans diffusion à tous (1.3.12) : avant, chaque changement d'une annonce partait en temps réel vers
--  TOUS les joueurs connectés (messages temps réel en joueurs × changements). Désormais :
--  - chaque joueur relit toutes les 2 minutes les annonces modifiées depuis sa dernière lecture (dc_market_since),
--    y compris celles supprimées, gardées 2 jours dans market_gone par un déclencheur ;
--  - seul le propriétaire d'une annonce est prévenu en direct quand ses propositions changent (table pings,
--    une ligne par joueur, lisible par lui seul, suivie en temps réel) ; les autres joueurs concernés le sont
--    déjà par leur propre profil (carte rendue ou reçue).
--  Les fonctions d'échange ne changent pas : tout passe par des déclencheurs sur docs.
-- ============================================================
create table if not exists public.market_gone (path text primary key, at timestamptz not null default now());
create index if not exists market_gone_at_idx on public.market_gone (at);
alter table public.market_gone enable row level security;
revoke all on public.market_gone from anon, authenticated;

create table if not exists public.pings (uid uuid primary key, at bigint not null);
alter table public.pings enable row level security;
revoke all on public.pings from anon, authenticated;
grant select on public.pings to authenticated;
drop policy if exists pings_self on public.pings;
create policy pings_self on public.pings for select to authenticated using (uid = auth.uid());
do $$ begin alter publication supabase_realtime add table public.pings; exception when others then null; end $$;

create or replace function public.dc__market_trg() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'DELETE' then
    if old.coll = 'market' then
      insert into public.market_gone (path) values (old.path) on conflict (path) do update set at = now();
      if random() < .02 then delete from public.market_gone where at < now() - interval '2 days'; end if;
    end if;
    return null;
  end if;
  if new.coll = 'market' and new.data ->> 'owner' is not null and (old.data -> 'offers') is distinct from (new.data -> 'offers') then
    insert into public.pings (uid, at) values ((new.data ->> 'owner')::uuid, public.dc__now()) on conflict (uid) do update set at = excluded.at;
  end if;
  -- 1.4.0 : profil modifié (par soi ou par un autre joueur : échange conclu, carte rendue, cadeau…) : son joueur est prévenu
  -- par sa ligne de pings, à la place de la diffusion du profil entier en temps réel (voir plus bas)
  if new.coll = 'players' and new.upd is distinct from old.upd then
    insert into public.pings (uid, at) values (substr(new.path, 9)::uuid, public.dc__now()) on conflict (uid) do update set at = excluded.at;
  end if;
  return null;
end $$;
drop trigger if exists dc_market_trg on public.docs;
create trigger dc_market_trg after update or delete on public.docs for each row execute function public.dc__market_trg();

-- annonces modifiées ou supprimées depuis p_since (la page garde 2 minutes de marge pour les écritures en cours)
create or replace function public.dc_market_since(p_since timestamptz) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'updated_at', updated_at, 'data', data)) from public.docs
                      where coll = 'market' and updated_at >= p_since), '[]'),
    'gone', coalesce((select jsonb_agg(path) from public.market_gone where at >= p_since), '[]'),
    'now', now()) $$;

-- ============================================================
--  Allègement du serveur (1.3.20) : les lectures fréquentes ne décompressent plus tout le profil.
--  - upd     : date de mise à jour du profil (« mon profil a-t-il changé ? », dates des auteurs d'annonces) ;
--  - summary : résumé du classement (pseudo, image, titres affichés, compteurs), lu toutes les 5 minutes par chaque joueur.
--  Colonnes calculées par PostgreSQL à chaque écriture d'un profil (generated stored) : une seule fois, au lieu d'à
--  chaque lecture. Index du marché pour la lecture des annonces modifiées (dc_market_since, toutes les 2 minutes).
--  Ajout des colonnes : la table est réécrite une fois (quelques secondes). Relançable sans risque.
-- ============================================================
create or replace function public.dc__summary(d jsonb) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('pseudo', d -> 'pseudo', 'avatar', d -> 'avatar', 'alpha', d -> 'alpha', 'beta', d -> 'beta',
    'shown', d -> 'shown', 'unique', d -> 'unique', 'total', d -> 'total', 'credits', d -> 'credits', 'myth', d -> 'myth', 'trans', d -> 'trans',
    'byr', d -> 'byr', 'byrV', d -> 'byrV', 'masterTs', d -> 'masterTs', 'vis', d -> 'vis', 'shinyN', d -> 'shinyN', 'avaS', d -> 'avaS')) $$;
alter table public.docs add column if not exists upd bigint generated always as ((data ->> 'updated')::numeric::bigint) stored;
alter table public.docs add column if not exists summary jsonb generated always as (case when coll = 'players' then public.dc__summary(data) end) stored;
create index if not exists docs_market_upd_idx on public.docs (updated_at) where coll = 'market';
analyze public.docs;

-- 1.4.0 : la table docs quitte le temps réel. Le décodage du journal des modifications (WAL) pour le temps réel prenait 44 % du
-- temps du serveur : chaque action réécrit le profil entier du joueur, collection comprise, et tout était décodé pour être
-- diffusé. Seule la petite table pings reste diffusée : un signal par joueur (profil modifié, propositions reçues), après
-- lequel la page relit ce qui a changé (colonnes légères upd et summary).
do $$ begin alter publication supabase_realtime drop table public.docs; exception when others then null; end $$;

-- ============================================================
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
revoke all on function public.dc__summary(jsonb) from public, anon, authenticated;
revoke all on function public.dc__market_trg() from public, anon, authenticated;
revoke all on function public.dc_market_since(timestamptz) from public, anon;
grant execute on function public.dc_market_since(timestamptz) to authenticated;
revoke all on function public.dc__open_special(jsonb,jsonb,text,integer,integer) from public, anon, authenticated;
revoke all on function public.dc_open_special(text,integer,integer) from public, anon;
grant execute on function public.dc_open_special(text,integer,integer) to authenticated;
revoke all on function public.dc__sp_key(jsonb,text,integer) from public, anon, authenticated;
revoke all on function public.dc_buy_special(text,integer,integer) from public, anon;
grant execute on function public.dc_buy_special(text,integer,integer) to authenticated;
revoke all on function public.dc_admin_give_booster(uuid,text,integer,integer) from public, anon;
grant execute on function public.dc_admin_give_booster(uuid,text,integer,integer) to authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'dc%' and (p.proconfig is null or not exists
             (select 1 from unnest(p.proconfig) c where c like 'search_path=%')) loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 4 OK' as verif, (select count(*) from pg_proc where proname in ('dc_open_special', 'dc_buy_special', 'dc_admin_give_booster')) as fonctions;
