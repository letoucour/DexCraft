-- ============================================================
--  DexCraft 0.4.0 — le serveur devient l'arbitre (anti-triche)
--  PARTIE 1 / 3. À coller dans Supabase > SQL Editor > Run, APRÈS dexcraft-supabase.sql et dexcraft-config.sql,
--  puis lancer dexcraft-serveur-2.sql.
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

-- ---------- ancien verrou (remplacé par les verrous des fonctions ci-dessous) ----------
drop function if exists public.acquire_lease(text, text, timestamptz);

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

-- carte reçue : ajoutée et comptée dans got (chance shiny, 1.1.0) ; une carte rendue passe par dc__add seul
create or replace function public.dc__gain(d jsonb, id int, n int) returns jsonb language sql immutable as
$$ select jsonb_set(public.dc__add(d, id, n), '{got}', coalesce(d -> 'got', '{}') || jsonb_build_object(id::text, coalesce((d -> 'got' ->> id::text)::int, 0) + n)) $$;

create or replace function public.dc__bump(d jsonb, k text, n bigint default 1) returns jsonb language sql immutable as
$$ select jsonb_set(d, '{stats}', coalesce(d -> 'stats', '{}') || jsonb_build_object(k, coalesce((d -> 'stats' ->> k)::bigint, 0) + n)) $$;

create or replace function public.dc__rar(cfg jsonb, id int) returns int language sql immutable as
$$ select (cfg -> 'rar' ->> id::text)::int $$;

-- profil complet avec toutes ses valeurs par défaut
create or replace function public.dc__norm(d jsonb) returns jsonb language plpgsql volatile as $$
declare cfg jsonb := public.dc__cfg();
begin
  d := jsonb_build_object('coll', '{}'::jsonb, 'bought', '{}'::jsonb,
         'fav', '{}'::jsonb, 'stats', '{}'::jsonb, 'volto', jsonb_build_object('day', '', 'gained', 0, 'level', 1),
         'credits', cfg -> 'startCredits', 'packs', cfg -> 'maxp', 'packTs', public.dc__now(), 'bonus', 0,
         'avatar', null, 'pseudo', '', 'dev', false, 'alpha', false, 'created', public.dc__now())
       || coalesce(d, '{}'::jsonb);
  if jsonb_typeof(d -> 'volto') <> 'object' then d := jsonb_set(d, '{volto}', jsonb_build_object('day', '', 'gained', 0, 'level', 1)); end if;
  if jsonb_typeof(d -> 'stats') <> 'object' then d := jsonb_set(d, '{stats}', '{}'); end if;
  -- shiny (1.1.0) : got = fois où chaque carte a été obtenue ; shiny = versions shiny débloquées {id: date}
  if jsonb_typeof(d -> 'got') is distinct from 'object' then d := jsonb_set(d, '{got}', '{}'); end if;
  if jsonb_typeof(d -> 'shiny') is distinct from 'object' then d := jsonb_set(d, '{shiny}', '{}'); end if;
  return d;
end $$;

-- un titre est-il obtenu ? (1.5.0 : sorti de dc__stamp, qui s'en sert aussi pour les titres acquis au prestige)
create or replace function public.dc__title_ok(cfg jsonb, def jsonb, d jsonb, newcoll jsonb, nmaster int, byr int[], gencnt int[], typecnt int[], nsec int) returns boolean language sql stable as $$
  select case def ->> 'c'
    when 'flag' then coalesce(d ->> (def ->> 'f'), '') = 'true'
    when 'beta' then (cfg ->> 'betaOpen')::boolean or coalesce(d ->> 'beta', '') = 'true'
    when 'secret' then nsec > 0
    when 'sflag' then coalesce(d -> 'stats' ->> (def ->> 's'), '') not in ('', '0', 'false', 'null')
    when 'stat' then coalesce((d -> 'stats' ->> (def ->> 's'))::numeric, 0) >= (def ->> 'n')::numeric
    when 'dex' then nmaster >= (def ->> 'n')::int
    when 'rar' then byr[(def ->> 'r')::int + 1] >= (def ->> 'n')::int
    when 'gen' then gencnt[(def ->> 'g')::int] >= (def ->> 'n')::int
    when 'type' then typecnt[(def ->> 't')::int] >= (def ->> 'n')::int
    when 'ids' then (select count(*) from jsonb_array_elements_text(def -> 'ids') x where newcoll ? x) >= (def ->> 'n')::int
    when 'evo' then (select count(distinct x) from jsonb_each(cfg -> 'evo') e, jsonb_array_elements_text(e.value) x where newcoll ? x) >= (def ->> 'n')::int  -- Darwiniste (1.1.3)
    when 'cos' then coalesce(d -> 'cos', '{}') ? (def ->> 'i')
    when 'shids' then (select count(*) from jsonb_array_elements_text(def -> 'ids') x where coalesce(d -> 'shiny', '{}') ? x) >= (def ->> 'n')::int  -- 1.5.14 : shiny de ces cartes
    -- Titré (1.5.8) : n titres différents obtenus (acquis au prestige compris), lui-même exclu
    when 'ntitles' then (select count(*) from jsonb_array_elements_text(cfg -> 'titleKeys') k where cfg -> 'titleDefs' -> k ->> 'c' <> 'ntitles'
      and (coalesce(d -> 'titlesKept' ? k, false) or public.dc__title_ok(cfg, cfg -> 'titleDefs' -> k, d, newcoll, nmaster, byr, gencnt, typecnt, nsec))) >= (def ->> 'n')::int
    when 'all' then not exists (select 1 from jsonb_array_elements_text(def -> 'keys') k where not (coalesce(d -> 'titlesKept' ? k, false)   -- 1.7.0 : catégorie complète
      or public.dc__title_ok(cfg, cfg -> 'titleDefs' -> k, d, newcoll, nmaster, byr, gencnt, typecnt, nsec)))
    else false end $$;

-- champs calculés (classement, titres…) : jamais fournis par le joueur
create or replace function public.dc__stamp(d jsonb, own boolean) returns jsonb language plpgsql volatile as $$
declare
  cfg jsonb := public.dc__cfg(); r record; n int; rr int;
  newcoll jsonb := '{}'; byr int[] := array[0,0,0,0,0,0,0,0,0];   -- 9e case : cartes spéciales (1.4.17)
  uniq int := 0; myth int := 0; trans int := 0; tot bigint := 0; nmaster int := 0;
  now_ms bigint := public.dc__now(); tk jsonb; id int; t int;
  gencnt int[] := array_fill(0, array[9]); typecnt int[] := array_fill(0, array[18]);
  pgen text := cfg ->> 'pgen'; ptype text := cfg ->> 'ptype'; def jsonb; ok boolean; shown jsonb := '[]';
  vis jsonb; ot jsonb; o2 jsonb; q record; rarm jsonb;
begin
  d := public.dc__norm(d) - 'listings' - 'escrow';
  -- 1.4.3 : collection en une requête, raretés lues une fois (CLAUDE.md)
  rarm := cfg -> 'rar';
  select coalesce(jsonb_object_agg(key, cnt), '{}') into newcoll from (
    select key, floor((value #>> '{}')::numeric)::int cnt from jsonb_each(d -> 'coll') where jsonb_typeof(value) = 'number') s
    where cnt > 0 and rarm ? key;
  for r in select key, (value #>> '{}')::int v from jsonb_each(newcoll) loop
    n := r.v; rr := (rarm ->> r.key)::int;
    byr[rr + 1] := byr[rr + 1] + 1; tot := tot + n;
    id := r.key::int;
    if id <= 1025 then
      uniq := uniq + 1;
      if pgen is not null then       -- compteurs par génération et par type, pour les titres Régions et Types
        t := substr(pgen, id, 1)::int; gencnt[t] := gencnt[t] + 1;
        t := ascii(substr(ptype, 2 * id - 1, 1)) - 96; if t between 1 and 18 then typecnt[t] := typecnt[t] + 1; end if;
        t := ascii(substr(ptype, 2 * id, 1)) - 96; if t between 1 and 18 then typecnt[t] := typecnt[t] + 1; end if;
      end if;
    end if;
    if rr = 6 then myth := myth + 1; elsif rr = 7 then trans := trans + 1; end if;
    if rr <= 5 then nmaster := nmaster + 1; end if;
  end loop;
  d := d || jsonb_build_object('coll', newcoll, 'unique', uniq, 'myth', myth, 'trans', trans,
         'byr', to_jsonb(byr), 'byrV', cfg -> 'byrV', 'total', tot);
  if d ->> 'avatar' is not null and not (newcoll ? (d ->> 'avatar')) then d := jsonb_set(d, '{avatar}', 'null'); end if;
  d := jsonb_set(d, '{fav}', coalesce((select jsonb_object_agg(key, value) from jsonb_each(d -> 'fav') where newcoll ? key), '{}'));
  -- cartes recherchées (cloche) : retirées dès qu'elles entrent dans la collection, sauf celles posées
  -- sur une carte déjà possédée (1.0.9 : valeur {"t": date, "k": 1}), que le joueur retire lui-même
  if jsonb_typeof(d -> 'wish') = 'object' then
    d := jsonb_set(d, '{wish}', coalesce((select jsonb_object_agg(key, value) from jsonb_each(d -> 'wish') where not newcoll ? key or (jsonb_typeof(value) = 'object' and value ? 'k')), '{}'));
  elsif d ? 'wish' then d := d - 'wish'; end if;
  -- shiny (1.1.0) : nombre de shiny (classement, titres), forme normale choisie (shinyOff) seulement pour un shiny
  -- débloqué, image de profil en shiny (avaS) visible par tous
  n := (select count(*) from jsonb_object_keys(d -> 'shiny'));
  d := jsonb_set(d || jsonb_build_object('shinyN', n), '{stats,shinyN}', to_jsonb(n));
  if jsonb_typeof(d -> 'shinyOff') = 'object' then
    d := jsonb_set(d, '{shinyOff}', coalesce((select jsonb_object_agg(key, value) from jsonb_each(d -> 'shinyOff') where d -> 'shiny' ? key), '{}'));
  elsif d ? 'shinyOff' then d := d - 'shinyOff'; end if;
  -- depuis la 1.2.0, forme choisie avec l'image (avaSh) ; avant, celle affichée dans la collection
  if d ->> 'avatar' is not null and d -> 'shiny' ? (d ->> 'avatar') and (d ->> 'avaSh' = 'true' or not d ? 'avaSh'
     and not coalesce(d -> 'shinyOff', '{}') ? (d ->> 'avatar') and coalesce(d ->> 'shinyNorm', '') <> 'true') then d := jsonb_set(d, '{avaS}', 'true');
  else d := d - 'avaS'; end if;
  -- vitrine (1.1.6) : 6 cartes au plus, [{i: n°, s: 1 si montrée en shiny}] ; une carte montrée normale sort de la
  -- vitrine quand elle quitte la collection, une carte montrée en shiny reste (le shiny est acquis pour toujours)
  if jsonb_typeof(d -> 'vitrine') = 'array' then
    d := jsonb_set(d, '{vitrine}', coalesce((select jsonb_agg(v order by o) from jsonb_array_elements(d -> 'vitrine') with ordinality x(v, o)
      where jsonb_typeof(v) = 'object' and case when v ->> 's' = '1' then d -> 'shiny' ? (v ->> 'i') else newcoll ? (v ->> 'i') end), '[]'));
  elsif d ? 'vitrine' then d := d - 'vitrine'; end if;
  -- dresseur d'origine (1.1.13) : jamais plus d'exemplaires venus d'autres dresseurs que d'exemplaires possédés ;
  -- une défausse ou une évolution consomme donc d'abord les exemplaires au nom du joueur
  if jsonb_typeof(d -> 'ot') = 'object' then
    ot := '{}';
    for r in select key, value from jsonb_each(d -> 'ot') loop
      n := coalesce((newcoll ->> r.key)::int, 0); o2 := '{}';
      for q in select key, (value #>> '{}')::int v from jsonb_each(case when jsonb_typeof(r.value) = 'object' then r.value else '{}' end) order by key loop
        exit when n <= 0;
        if q.v > 0 then o2 := o2 || jsonb_build_object(q.key, least(q.v, n)); n := n - least(q.v, n); end if;
      end loop;
      if o2 <> '{}' then ot := ot || jsonb_build_object(r.key, o2); end if;
    end loop;
    d := case when ot = '{}' then d - 'ot' else jsonb_set(d, '{ot}', ot) end;
  elsif d ? 'ot' then d := d - 'ot'; end if;
  -- cosmétiques (0.9.0) : articles possédés (cos) ; portés (look), seulement s'ils sont possédés ;
  -- partie visible par les autres joueurs (vis : cadre, couleur du pseudo, badges), lue par le classement
  if d ? 'cos' and jsonb_typeof(d -> 'cos') <> 'object' then d := d - 'cos'; end if;
  if jsonb_typeof(d -> 'look') = 'object' then
    d := jsonb_set(d, '{look}', coalesce((select jsonb_object_agg(key, value) from jsonb_each_text(d -> 'look')
      where coalesce(d -> 'cos', '{}') ? value and value like key || '.%'), '{}'));
  elsif d ? 'look' then d := d - 'look'; end if;
  vis := jsonb_strip_nulls(jsonb_build_object('f', d -> 'look' ->> 'cadre', 'p', d -> 'look' ->> 'pseudo',
    'b', (select jsonb_agg(k order by k) from jsonb_object_keys(coalesce(d -> 'cos', '{}')) k where k like 'badge.%')));
  if vis = '{}' then d := d - 'vis'; else d := jsonb_set(d, '{vis}', vis); end if;
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
  -- titres affichés à côté du nom (shown) : les titres choisis, ou ceux par défaut, réellement obtenus.
  -- Calculés ici pour que les autres joueurs n'aient pas à télécharger toute la collection.
  -- Prestige (1.5.0) : tout titre obtenu est acquis pour toujours (titlesKept)
  if coalesce((d ->> 'prestige')::int, 0) > 0 then
    d := jsonb_set(d, '{titlesKept}', (select coalesce(jsonb_agg(distinct k), '[]') from (
      select jsonb_array_elements_text(case when jsonb_typeof(d -> 'titlesKept') = 'array' then d -> 'titlesKept' else '[]' end) k
      union select k from jsonb_array_elements_text(cfg -> 'titleKeys') k
        where public.dc__title_ok(cfg, cfg -> 'titleDefs' -> k, d, newcoll, nmaster, byr, gencnt, typecnt, myth + trans)) s));
  end if;
  for r in select value #>> '{}' as k, ordinality as i
           from jsonb_array_elements(case when jsonb_typeof(d -> 'titles') = 'array' then d -> 'titles' else cfg -> 'titleDefault' end) with ordinality loop
    def := cfg -> 'titleDefs' -> r.k;
    if def is null then continue; end if;
    ok := coalesce(d -> 'titlesKept' ? r.k, false) or public.dc__title_ok(cfg, def, d, newcoll, nmaster, byr, gencnt, typecnt, myth + trans);
    if ok then shown := shown || jsonb_build_array(jsonb_build_object('k', r.k, 'o', case r.k when 'alpha' then 0 when 'beta' then 1 else 2 end, 'i', r.i)); end if;
  end loop;
  select coalesce(jsonb_agg(x -> 'k' order by (x ->> 'o')::int, (x ->> 'i')::int), '[]') into shown
    from (select x from jsonb_array_elements(shown) x order by (x ->> 'o')::int, (x ->> 'i')::int limit (cfg ->> 'titleMax')::int) s;
  d := jsonb_set(d, '{shown}', shown);
  return jsonb_set(d, '{updated}', to_jsonb(now_ms));
end $$;

-- verrouille un profil (le crée si besoin pour le joueur lui-même)
create or replace function public.dc__lock(u uuid, create_it boolean default false) returns jsonb language plpgsql volatile as $$
declare d jsonb;
begin
  select data into d from public.docs where path = 'players/' || u for update;
  if found then return public.dc__norm(d); end if;
  if not create_it then raise exception 'Joueur introuvable.'; end if;
  -- pseudo provisoire neutre (jamais tiré de l'e-mail), choisi à la première connexion
  d := public.dc__norm(jsonb_build_object('pseudo', 'Dresseur ' || lpad(public.dc__rnd(10000)::text, 4, '0'), 'pseudoSet', false));
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

-- clé de comparaison d'un pseudo : minuscules, sans accents, sans espaces ni ponctuation
create or replace function public.dc__pseudo_key(v text) returns text language sql immutable as
$$ select regexp_replace(translate(lower(coalesce(v, '')), 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ', 'aaaaaaceeeeiiiinooooouuuuyyoa'), '[^a-z0-9]', '', 'g') $$;

-- pseudo valide et libre (3 à 20 caractères, unique, ni réservé ni injurieux) ; renvoie le pseudo nettoyé
create or replace function public.dc__pseudo_check(p_v text, u uuid, admin boolean default false) returns text language plpgsql volatile as $$
declare v text := btrim(regexp_replace(coalesce(p_v, ''), '\s+', ' ', 'g')); k text; w text;
begin
  if char_length(v) < 3 or char_length(v) > 20 then raise exception 'Le pseudo doit faire entre 3 et 20 caractères.'; end if;
  if v !~ '^[A-Za-z0-9À-ÖØ-öø-ÿŒœ _.''-]+$' then raise exception 'Le pseudo ne peut contenir que des lettres, des chiffres, des espaces et les signes . _ -'; end if;
  k := public.dc__pseudo_key(v);
  if char_length(k) < 3 then raise exception 'Le pseudo doit contenir au moins 3 lettres ou chiffres.'; end if;
  foreach w in array array['pute','salope','connard','connasse','encule','batard','nazi','hitler','negre','negro','nique','pedophil','pedo',
    'fdp','ntm','tamere','tagueule','couille','bite','zizi','penis','chatte','merde','fuck','shit','bitch','whore','nigg','cunt','porn',
    'sexe','terroris','daech'] loop
    if position(w in k) > 0 then raise exception 'Ce pseudo n’est pas autorisé.'; end if;
  end loop;
  if not admin and (k in ('admin', 'modo', 'staff', 'support', 'officiel', 'systeme')
     or k like '%theotoucour%' or k like '%dexcraft%' or k like '%administrat%' or k like '%moderat%') then
    raise exception 'Ce pseudo est réservé.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pseudo:' || k));   -- deux joueurs ne prennent pas le même au même instant
  if exists (select 1 from public.docs where coll = 'players' and path <> 'players/' || u and public.dc__pseudo_key(data ->> 'pseudo') = k) then
    raise exception 'Ce pseudo est déjà pris.';
  end if;
  return v;
end $$;

-- pseudo : obligatoire à la première connexion (pseudoSet), puis un changement tous les 7 jours
create or replace function public.dc_set_pseudo(p_v text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); v text;
  nx bigint := public.dc__int(d, 'pseudoTs') + (public.dc__cfg() ->> 'pseudoWait')::bigint; is_first boolean;
begin
  is_first := not coalesce((d ->> 'pseudoSet')::boolean, false);
  v := public.dc__pseudo_check(p_v, u);
  if v = coalesce(d ->> 'pseudo', '') and not is_first then raise exception 'C’est déjà votre pseudo.'; end if;
  if not is_first and public.dc__int(d, 'pseudoTs') > 0 and nx > public.dc__now() then raise exception 'Vous ne pouvez pas encore changer de pseudo.'; end if;
  d := d || jsonb_build_object('pseudo', v, 'pseudoTs', public.dc__now(), 'pseudoSet', true);
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

drop function if exists public.dc_set_avatar(int);   -- remplacée par la version avec p_shiny (1.2.0)
create or replace function public.dc_set_avatar(p_id int, p_shiny boolean default false) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); h jsonb; e jsonb;
begin
  if public.dc__count(d, p_id) < 1 then raise exception 'Ce Pokémon n’est plus dans votre collection.'; end if;
  if p_shiny and not (d -> 'shiny' ? p_id::text) then raise exception 'Vous n’avez pas encore ce Pokémon en shiny.'; end if;
  -- 5 dernières images (avaHist, 0.6.9) ; une image shiny s'y note {"i": n°, "s": 1}
  e := case when p_shiny then jsonb_build_object('i', p_id, 's', 1) else to_jsonb(p_id) end;
  h := case when jsonb_typeof(d -> 'avaHist') = 'array' then d -> 'avaHist' else '[]' end;
  if jsonb_array_length(h) = 0 and d ->> 'avatar' is not null and d -> 'avatar' <> 'null' then h := jsonb_build_array(d -> 'avatar'); end if;
  select coalesce(jsonb_agg(v order by o), '[]') into h from (
    select v, o from (select e as v, 0 as o
                      union all
                      select v, o from jsonb_array_elements(h) with ordinality as x(v, o) where v <> e) s
    order by o limit 5) t;
  return jsonb_build_object('profile', public.dc__save(u, d || jsonb_build_object('avatar', p_id, 'avaSh', p_shiny, 'avaHist', h)));
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
  b int; i int; r int; x int; k int; id int; legend int; pk record; drawn jsonb := '[]'; pool jsonb; sh boolean;
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
      pool := coalesce(cfg -> 'pool' -> (r::text), cfg -> 'byr' -> r); -- réserves de tirage (1.1.8) : Méga et Gigamax de légendaires tirées avec les Légendaires
      id := (pool ->> public.dc__rnd(jsonb_array_length(pool)))::int;
      -- shiny (1.1.0) : (1 + fois obtenue) sur 4 096 ; jamais pour une carte secrète ou sans illustration shiny
      sh := false;
      if r <= 5 and cfg ? 'shinyBase' and not (cfg -> 'shinyNo' @> to_jsonb(id)) and not (d -> 'shiny' ? id::text) then
        sh := public.dc__rnd((cfg ->> 'shinyBase')::int) < 1 + least(coalesce((d -> 'got' ->> id::text)::int, 0) + coalesce((cfg ->> 'presCharm')::int, 15) * coalesce((d ->> 'prestige')::int, 0), (cfg ->> 'shinyMax')::int - 1);   -- + Charmes Chroma (1.5.0)
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
  -- dernier tirage gardé : si la réponse se perd, le jeu le relit
  d := d || jsonb_build_object('lastOpen', jsonb_build_object('t', now_ms, 'drawn', drawn));
  -- 50 dernières cartes tirées (1.2.0), les plus récentes d'abord, à revoir depuis l'écran des boosters
  d := d || jsonb_build_object('recent', (select jsonb_agg(v order by o) from jsonb_array_elements(drawn || coalesce(d -> 'recent', '[]'))
    with ordinality as x(v, o) where o <= 50));
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
    if public.dc__rar(cfg, r.key::int) >= 6 then raise exception 'Cette carte ne peut pas être défaussée.'; end if;  -- 1.5.14 : raretés 6 à 8
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
  -- 1.7.1 : on garde toujours un exemplaire
  if public.dc__count(d, p_from) <= (cfg ->> 'evoCost')::int then raise exception 'Il vous faut % exemplaires (vous en gardez toujours un).', (cfg ->> 'evoCost')::int + 1; end if;
  was_new := public.dc__count(d, p_to) = 0;
  d := public.dc__gain(public.dc__add(d, p_from, -(cfg ->> 'evoCost')::int), p_to, 1);
  d := public.dc__bump(d, 'evos');
  return jsonb_build_object('profile', public.dc__save(u, d), 'wasNew', was_new);
end $$;

-- Évolution rapide : Pokémon en 4 exemplaires ou plus (il en reste toujours au moins 1).
-- p_all = false : seulement quand une évolution manque encore ; p_all = true (1.1.1) : aussi quand on a déjà
-- toutes ses évolutions, en choisissant celle qu'on a le moins (les manquantes d'abord).
drop function if exists public.dc_quick_evo();
create or replace function public.dc_quick_evo(p_all boolean default false) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  cost int := (cfg ->> 'evoCost')::int; r record; t jsonb; done jsonb := '[]'; guard int; target int; best int; n int;
begin
  for r in select key::int id from jsonb_each(d -> 'coll') where cfg -> 'evo' ? key
           order by (value #>> '{}')::int desc, key::int loop
    guard := 0;
    while public.dc__count(d, r.id) >= cost + 1 and guard < 60 loop
      guard := guard + 1; target := null; best := null;
      for t in select value from jsonb_array_elements(cfg -> 'evo' -> r.id::text) loop
        n := public.dc__count(d, (t #>> '{}')::int);
        if (n = 0 or coalesce(p_all, false)) and (best is null or n < best) then target := (t #>> '{}')::int; best := n; end if;
      end loop;
      exit when target is null;
      d := public.dc__gain(public.dc__add(d, r.id, -cost), target, 1);
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
  if o ? 'until' and public.dc__now() >= (o ->> 'until')::bigint then raise exception 'Cette offre est terminée.'; end if;   -- offre limitée (1.2.0)
  if not ((o ->> 'free')::boolean or (public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false))) then
    raise exception 'Paiement indisponible pendant la bêta.';
  end if;
  d := jsonb_set(d, '{bought}', (d -> 'bought') || jsonb_build_object(p_key, public.dc__now()));
  d := d || jsonb_build_object('credits', public.dc__int(d, 'credits') + (o ->> 'credits')::bigint, 'bonus', public.dc__int(d, 'bonus') + (o ->> 'packs')::int);
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;


-- ============================================================
--  Droits d'exécution des fonctions de cette partie (les dc__* restent internes)
-- ============================================================
revoke all on function public.dc__add(jsonb,integer,integer) from public, anon, authenticated;
revoke all on function public.dc__gain(jsonb,integer,integer) from public, anon, authenticated;
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
revoke all on function public.dc__rnd(integer) from public, anon, authenticated;
revoke all on function public.dc__save(uuid,jsonb,boolean) from public, anon, authenticated;
revoke all on function public.dc__stamp(jsonb,boolean) from public, anon, authenticated;
revoke all on function public.dc__uid() from public, anon, authenticated;
revoke all on function public.dc__pseudo_key(text) from public, anon, authenticated;
revoke all on function public.dc__pseudo_check(text,uuid,boolean) from public, anon, authenticated;
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
revoke all on function public.dc_quick_evo(boolean) from public, anon;
grant execute on function public.dc_quick_evo(boolean) to authenticated;
revoke all on function public.dc_set_avatar(integer,boolean) from public, anon;
grant execute on function public.dc_set_avatar(integer,boolean) to authenticated;
revoke all on function public.dc_set_pseudo(text) from public, anon;
grant execute on function public.dc_set_pseudo(text) to authenticated;
revoke all on function public.dc_set_titles(jsonb) from public, anon;
grant execute on function public.dc_set_titles(jsonb) to authenticated;
revoke all on function public.dc__title_ok(jsonb,jsonb,jsonb,jsonb,integer,integer[],integer[],integer[],integer) from public, anon, authenticated;
revoke all on function public.dc_toggle_fav(integer) from public, anon;
grant execute on function public.dc_toggle_fav(integer) to authenticated;

-- fonctions internes : chemin de recherche fixé (avertissement « Function Search Path Mutable » de Supabase)
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'dc\_%' and p.proconfig is null loop
    execute format('alter function %s set search_path = public, extensions', f);
  end loop;
end $$;

select 'serveur DexCraft 0.4.0 partie 1 OK' as verif, count(*) as fonctions from pg_proc where proname like 'dc\_%';
