-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 8 (1.10.0) : récompense du jour en calendrier de 30 jours, événements, défis du jour
--  et notifications. À lancer après les parties 1 à 7 et la configuration (clés daily, events et defis).
--  Les notifications partent de la fonction Supabase dc-push (supabase/functions/dc-push), appelée toutes les 2 minutes par
--  pg_cron (tâche dc-push, plus bas) ; elle demande au serveur ce qu'il faut envoyer (dc_push_due), puis l'envoie.
-- ============================================================

-- ---------- récompense de connexion quotidienne (0.6.0 ; calendrier de 30 jours depuis la 1.10.0, demande de Theo) ----------
-- Une fois par jour (heure de Paris). Série de jours (daily.streak), qui repart à 1 si un jour est manqué et recommence après le
-- dernier jour du calendrier (cfg.daily : crédits, boosters, Boosters Premium rangés dans l'inventaire). Passage de 7 à 30 jours
-- (1.10.0) : la série en cours continue, un joueur au 7e jour passe au 8e au lieu de recommencer.
create or replace function public.dc_daily_claim() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  today text := public.dc__day(); yest text := to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD');
  last text := coalesce(d -> 'daily' ->> 'day', ''); st int := coalesce((d -> 'daily' ->> 'streak')::int, 0); rw jsonb; pr int;
begin
  if last = today then raise exception 'Récompense du jour déjà récupérée. Revenez demain !'; end if;
  st := case when last = yest then st % jsonb_array_length(cfg -> 'daily') + 1 else 1 end;
  rw := cfg -> 'daily' -> (st - 1); pr := coalesce((rw ->> 'prem')::int, 0);
  d := d || jsonb_build_object('daily', jsonb_build_object('day', today, 'streak', st),
    'credits', public.dc__int(d, 'credits') + coalesce((rw ->> 'credits')::bigint, 0),
    'bonus', public.dc__int(d, 'bonus') + coalesce((rw ->> 'packs')::int, 0));
  if pr > 0 then
    d := jsonb_set(d, '{spInv}', coalesce(d -> 'spInv', '{}') || jsonb_build_object('prem', coalesce((d -> 'spInv' ->> 'prem')::int, 0) + pr));
  end if;
  return jsonb_build_object('profile', public.dc__save(u, d), 'streak', st, 'credits', coalesce((rw ->> 'credits')::bigint, 0),
    'packs', coalesce((rw ->> 'packs')::int, 0), 'prem', pr);
end $$;

-- ---------- événements (1.10.0) ----------
-- cfg.events : {k, n, from, to (AAAA-MM-JJ, heure de Paris, inclus), fx : effets (dc__evfx, partie 4), pack : cadeau à récupérer
-- une fois par joueur pendant l'événement {credits, packs, prem}}. Le pack de bienvenue passe par l'ancienne offre de lancement
-- (cfg.once, dc_buy_once) : pas de champ pack pour lui.
create or replace function public.dc_event_claim(p_k text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); e jsonb; pk jsonb; today text := public.dc__day();
begin
  select x into e from jsonb_array_elements(coalesce(public.dc__cfg() -> 'events', '[]')) x where x ->> 'k' = p_k;
  if e is null or not (today between e ->> 'from' and e ->> 'to') then raise exception 'Cet événement est terminé.'; end if;
  pk := e -> 'pack';
  if pk is null then raise exception 'Cet événement n’a pas de cadeau.'; end if;
  if coalesce(d -> 'evGot', '{}') ? p_k then raise exception 'Vous avez déjà récupéré ce cadeau.'; end if;
  d := d || jsonb_build_object('evGot', coalesce(d -> 'evGot', '{}') || jsonb_build_object(p_k, today),
    'credits', public.dc__int(d, 'credits') + coalesce((pk ->> 'credits')::bigint, 0),
    'bonus', public.dc__int(d, 'bonus') + coalesce((pk ->> 'packs')::int, 0));
  if coalesce((pk ->> 'prem')::int, 0) > 0 then
    d := jsonb_set(d, '{spInv}', coalesce(d -> 'spInv', '{}') || jsonb_build_object('prem', coalesce((d -> 'spInv' ->> 'prem')::int, 0) + (pk ->> 'prem')::int));
  end if;
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

-- ---------- défis du jour (1.10.0, demande de Theo) ----------
-- Chaque jour (heure de Paris), cfg.defis.n défis tirés au hasard dans cfg.defis.list ({k, s : compteur de stats, need}). La
-- progression d'un défi = compteur actuel moins sa valeur au tirage (b) : aucun jeu n'a besoin de les connaître. Chaque défi réussi
-- rapporte cfg.defis.reward, les trois réunis cfg.defis.bonus. Profil : defis = {day, l : [{k, s, need, b}], got : [k…]}.
create or replace function public.dc__defi_new(d jsonb, cfg jsonb) returns jsonb language plpgsql volatile as $$
declare today text := public.dc__day(); l jsonb;
begin
  if d -> 'defis' ->> 'day' = today then return d; end if;
  select coalesce(jsonb_agg(jsonb_build_object('k', x ->> 'k', 's', x ->> 's', 'need', (x ->> 'need')::int,
           'b', coalesce((d -> 'stats' ->> (x ->> 's'))::bigint, 0))), '[]') into l
    from (select x from jsonb_array_elements(coalesce(cfg -> 'defis' -> 'list', '[]')) x
          order by public.dc__rnd(1000000) limit coalesce((cfg -> 'defis' ->> 'n')::int, 3)) z;
  return d || jsonb_build_object('defis', jsonb_build_object('day', today, 'l', l, 'got', '[]'::jsonb));
end $$;

create or replace function public.dc_defi_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); d2 jsonb;
begin
  d2 := public.dc__defi_new(d, public.dc__cfg());
  if d2 is distinct from d then d := public.dc__save(u, d2); end if;
  return jsonb_build_object('profile', d);
end $$;

create or replace function public.dc_defi_claim(p_k text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); x jsonb; got jsonb; rw jsonb; bonus boolean := false;
begin
  if d -> 'defis' ->> 'day' is distinct from public.dc__day() then raise exception 'Ces défis sont terminés : de nouveaux vous attendent.'; end if;
  select v into x from jsonb_array_elements(d -> 'defis' -> 'l') v where v ->> 'k' = p_k;
  if x is null then raise exception 'Ce défi n’est pas un de vos défis du jour.'; end if;
  got := coalesce(d -> 'defis' -> 'got', '[]');
  if got @> to_jsonb(p_k) then raise exception 'Récompense déjà récupérée.'; end if;
  if coalesce((d -> 'stats' ->> (x ->> 's'))::bigint, 0) - (x ->> 'b')::bigint < (x ->> 'need')::int then raise exception 'Ce défi n’est pas encore réussi.'; end if;
  got := got || to_jsonb(p_k);
  rw := coalesce(cfg -> 'defis' -> 'reward', '{}');
  if jsonb_array_length(got) >= jsonb_array_length(d -> 'defis' -> 'l') then
    bonus := true; rw := jsonb_build_object('packs', coalesce((rw ->> 'packs')::int, 0) + coalesce((cfg -> 'defis' -> 'bonus' ->> 'packs')::int, 0),
      'prem', coalesce((rw ->> 'prem')::int, 0) + coalesce((cfg -> 'defis' -> 'bonus' ->> 'prem')::int, 0), 'credits', coalesce((rw ->> 'credits')::int, 0) + coalesce((cfg -> 'defis' -> 'bonus' ->> 'credits')::int, 0));
  end if;
  d := jsonb_set(d, '{defis,got}', got) || jsonb_build_object('credits', public.dc__int(d, 'credits') + coalesce((rw ->> 'credits')::bigint, 0),
    'bonus', public.dc__int(d, 'bonus') + coalesce((rw ->> 'packs')::int, 0));
  if coalesce((rw ->> 'prem')::int, 0) > 0 then
    d := jsonb_set(d, '{spInv}', coalesce(d -> 'spInv', '{}') || jsonb_build_object('prem', coalesce((d -> 'spInv' ->> 'prem')::int, 0) + (rw ->> 'prem')::int));
  end if;
  return jsonb_build_object('profile', public.dc__save(u, public.dc__bump(d, 'defis')), 'bonus', bonus);
end $$;

-- ============================================================
--  Notifications (1.10.0, demande de Theo : très peu, jamais de relance). Quatre seulement :
--   packs : les 10 boosters gratuits sont prêts (une fois par réserve remplie) ;
--   eggs  : tous les œufs de la Pension sont prêts à éclore (pension.end, une fois par couvée) ;
--   trade : quelqu'un a proposé une carte sur une de ses annonces (pas un échange automatique) ; une seule jusqu'au retour du
--           joueur dans le jeu (dc_push_seen) ;
--   maj   : mise à jour majeure (les deux premiers nombres de la version changent), une fois.
--  Le joueur les active dans Réglages (dc_push_sub, un abonnement par appareil).
-- ============================================================
create table if not exists public.push_subs (
  endpoint   text primary key,
  uid        uuid not null references auth.users (id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_uid on public.push_subs (uid);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

create table if not exists public.push_state (
  uid   uuid primary key references auth.users (id) on delete cascade,
  packs bigint not null default 0,     -- heure (ms) de la dernière réserve pleine signalée
  eggs  bigint not null default 0,     -- heure de la dernière couvée terminée signalée
  trade smallint not null default 0    -- 0 : rien ; 1 : proposition à signaler ; 2 : signalée, en attente du retour du joueur
);
alter table public.push_state enable row level security;
revoke all on public.push_state from anon, authenticated;

create table if not exists public.push_meta (k text primary key, v text);
alter table public.push_meta enable row level security;
revoke all on public.push_meta from anon, authenticated;

-- abonnement d'un appareil (navigateur) : ce qui s'est passé avant n'est jamais signalé
create or replace function public.dc_push_sub(p_endpoint text, p_p256dh text, p_auth text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); now_ bigint := public.dc__now();
begin
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(length(p_p256dh), 0) not between 40 and 200 or coalesce(length(p_auth), 0) not between 10 and 100 then
    raise exception 'Abonnement aux notifications invalide.'; end if;
  insert into public.push_subs (endpoint, uid, p256dh, auth) values (p_endpoint, u, p_p256dh, p_auth)
    on conflict (endpoint) do update set uid = excluded.uid, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  delete from public.push_subs where uid = u and endpoint not in (select endpoint from public.push_subs where uid = u order by created_at desc limit 10);
  insert into public.push_state (uid, packs, eggs) values (u, now_, now_)
    on conflict (uid) do update set packs = greatest(public.push_state.packs, now_), eggs = greatest(public.push_state.eggs, now_), trade = 0;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.dc_push_unsub(p_endpoint text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.push_subs where endpoint = p_endpoint and uid = public.dc__uid();
  return jsonb_build_object('ok', true);
end $$;

-- le joueur est revenu dans le jeu : une nouvelle proposition pourra de nouveau être signalée
create or replace function public.dc_push_seen() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.push_state set trade = 0 where uid = public.dc__uid() and trade <> 0;
  return jsonb_build_object('ok', true);
end $$;

-- nouvelle proposition sur une annonce (pas une annonce à acceptation automatique : l'échange se conclut aussitôt, rien à signaler)
create or replace function public.dc__push_trg() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.data ->> 'owner' is not null and coalesce(new.data ->> 'auto', '') <> 'true'
     and exists (select 1 from jsonb_each(coalesce(new.data -> 'offers', '{}')) o
                 where o.value ->> 'status' = 'pending' and not coalesce(old.data -> 'offers', '{}') ? o.key) then
    update public.push_state set trade = 1 where uid = (new.data ->> 'owner')::uuid and trade = 0;
  end if;
  return null;
end $$;
drop trigger if exists dc_push_trg on public.docs;
create trigger dc_push_trg after update on public.docs for each row
  when (new.coll = 'market' and old.data -> 'offers' is distinct from new.data -> 'offers') execute function public.dc__push_trg();

-- ce qu'il faut envoyer maintenant (appelée par la fonction Supabase dc-push, rôle service seulement) ; p_ver : version en ligne
-- (APP_VERSION lue sur le site), pour la notification de mise à jour majeure. Chaque notification est notée aussitôt comme envoyée.
create or replace function public.dc_push_due(p_ver text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cfg jsonb := public.dc__cfg(); now_ bigint := public.dc__now(); maxp int := (cfg ->> 'maxp')::int; per bigint := (cfg ->> 'per')::bigint;
  r record; d jsonb; full_ bigint; e bigint; out_ jsonb := '[]'; ks text[]; xy text; old text; maj boolean := false; kd text;
begin
  if p_ver ~ '^\d+\.\d+\.\d+$' then
    xy := substring(p_ver from '^\d+\.\d+');
    select v into old from public.push_meta where k = 'ver';
    if old is null then insert into public.push_meta (k, v) values ('ver', xy) on conflict (k) do update set v = excluded.v;
    elsif string_to_array(xy, '.')::int[] > string_to_array(old, '.')::int[] then
      update public.push_meta set v = xy where k = 'ver'; maj := true;
    end if;
  end if;
  for r in select s.uid, s.packs, s.eggs, s.trade from public.push_state s where exists (select 1 from public.push_subs b where b.uid = s.uid) for update of s loop
    select data into d from public.docs where path = 'players/' || r.uid;
    continue when d is null;
    ks := '{}';
    if public.dc__int(d, 'packs') < maxp then
      full_ := public.dc__int(d, 'packTs') + (maxp - public.dc__int(d, 'packs')) * per;
      if full_ <= now_ and full_ > r.packs then ks := ks || 'packs'::text; update public.push_state set packs = full_ where uid = r.uid; end if;
    end if;
    e := (d -> 'pension' ->> 'end')::bigint;
    if e is not null and e <= now_ and e > r.eggs then ks := ks || 'eggs'::text; update public.push_state set eggs = e where uid = r.uid; end if;
    if r.trade = 1 then ks := ks || 'trade'::text; update public.push_state set trade = 2 where uid = r.uid; end if;
    if maj then ks := ks || 'maj'::text; end if;
    foreach kd in array ks loop
      out_ := out_ || (select coalesce(jsonb_agg(jsonb_build_object('endpoint', b.endpoint, 'p256dh', b.p256dh, 'auth', b.auth, 'kind', kd,
          'title', case kd when 'packs' then 'Réserve pleine' when 'eggs' then 'Pension' when 'trade' then 'Échanges' else 'DexCraft ' || xy end,
          'body', case kd when 'packs' then 'Vos ' || maxp || ' boosters gratuits sont prêts à être ouverts.'
                         when 'eggs' then 'Tous vos œufs sont prêts à éclore.'
                         when 'trade' then 'Un joueur vous a proposé une carte en échange.'
                         else 'Une nouvelle version de DexCraft est disponible.' end)), '[]')
        from public.push_subs b where b.uid = r.uid);
    end loop;
  end loop;
  return out_;
end $$;

-- abonnements refusés par le service de notifications (appareil désinscrit, navigateur effacé…) : supprimés
create or replace function public.dc_push_drop(p_endpoints text[]) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.push_subs where endpoint = any (p_endpoints);
  return jsonb_build_object('ok', true);
end $$;

-- toutes les 2 minutes, pg_cron appelle la fonction Supabase dc-push (pg_net) avec le secret gardé dans le coffre de Supabase
-- (vault, nom dc_push_secret, créé par Theo dans l'éditeur SQL : jamais dans le dépôt)
do $$ begin
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  perform cron.schedule('dc-push', '*/2 * * * *', $c$select net.http_post(url := 'https://hxrbzhmzjeuhmaioqhdd.supabase.co/functions/v1/dc-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dc-secret',
      coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'dc_push_secret'), '')),
    body := '{}'::jsonb, timeout_milliseconds := 25000)$c$);
exception when others then raise warning 'Tâche des notifications non programmée (pg_cron ou pg_net indisponible) : %', sqlerrm;
end $$;

-- ============================================================
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('dc_daily_claim', 'dc_event_claim', 'dc__defi_new', 'dc_defi_state', 'dc_defi_claim',
             'dc_push_sub', 'dc_push_unsub', 'dc_push_seen', 'dc__push_trg', 'dc_push_due', 'dc_push_drop') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname in ('dc_push_due', 'dc_push_drop') then execute format('grant execute on function %s to service_role', f.sig);
    elsif f.proname not like 'dc\_\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 8 OK' as verif,
  (select count(*) from pg_proc where proname in ('dc_daily_claim', 'dc_event_claim', 'dc_defi_state', 'dc_defi_claim', 'dc_push_sub', 'dc_push_due')) as fonctions,
  to_regclass('cron.job') is not null as pg_cron_actif;
