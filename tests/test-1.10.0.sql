-- ============================================================
--  Tests de la 1.10.0 : calendrier de 30 jours, événements, défis du jour, Pension automatique, Lumi-Bois en éclats,
--  notifications. Base de test locale seulement (outils/tester-sql.ps1) : JAMAIS sur la vraie base.
--  Chaque ligne commence par OK ou ERR ; « (ERR attendu) » : l'erreur est voulue.
-- ============================================================
\set ON_ERROR_STOP 0
\pset footer off
\pset tuples_only on
insert into auth.users values ('11111111-1111-1111-1111-111111111111', 'a@t'), ('22222222-2222-2222-2222-222222222222', 'b@t') on conflict do nothing;
insert into public.admins values ('11111111-1111-1111-1111-111111111111') on conflict do nothing;
create or replace function pg_temp.t(who text, step text, q text) returns text language plpgsql as $f$
declare r jsonb; begin
  perform set_config('request.jwt.claim.sub', who, false);
  execute q into r;
  return 'OK   ' || step;
exception when others then return 'ERR  ' || step || ' : ' || sqlerrm;
end $f$;
create or replace function pg_temp.j(who text, q text) returns jsonb language plpgsql as $f$
declare r jsonb; begin perform set_config('request.jwt.claim.sub', who, false); execute q into r; return r; end $f$;
create or replace function pg_temp.chk(step text, ok boolean, detail text default '') returns text language sql as
$f$ select case when coalesce(ok, false) then 'OK   ' else 'ERR  ' end || step || case when not coalesce(ok, false) then ' : ' || coalesce(detail, '?') else '' end $f$;
create or replace function pg_temp.p(u text) returns jsonb language sql as $f$ select data from public.docs where path = 'players/' || u $f$;
create or replace function pg_temp.setp(u text, patch jsonb) returns void language sql as
$f$ update public.docs set data = data || patch where path = 'players/' || u $f$;
\set A '''11111111-1111-1111-1111-111111111111'''
\set B '''22222222-2222-2222-2222-222222222222'''
select pg_temp.t(:A, 'A init', $$select public.dc_init()$$);
select pg_temp.t(:B, 'B init', $$select public.dc_init()$$);
create temp table ev_avant as select data -> 'events' as ev from public.game_config where id = 1;

-- ===== calendrier de 30 jours =====
select pg_temp.setp(:A, jsonb_build_object('daily', jsonb_build_object('day', to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD'), 'streak', 7), 'credits', 0, 'bonus', 0, 'spInv', '{}'::jsonb));
create temp table d1 as select pg_temp.j(:A, $$select public.dc_daily_claim()$$) r;
select pg_temp.chk('série en cours au 7e jour : jour 8 (3 boosters, 300 crédits)', (r ->> 'streak')::int = 8 and (r ->> 'packs')::int = 3 and (r ->> 'credits')::int = 300, r::text) from d1;
select pg_temp.t(:A, 'deuxième récompense le même jour (ERR attendu)', $$select public.dc_daily_claim()$$);
select pg_temp.setp(:A, jsonb_build_object('daily', jsonb_build_object('day', to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD'), 'streak', 14)));
create temp table d2 as select pg_temp.j(:A, $$select public.dc_daily_claim()$$) r;
select pg_temp.chk('jour 15 : 2 Boosters Premium dans l''inventaire et 920 crédits', (r ->> 'streak')::int = 15 and (r ->> 'prem')::int = 2 and (pg_temp.p(:A) -> 'spInv' ->> 'prem')::int = 2, r::text) from d2;
select pg_temp.setp(:A, jsonb_build_object('daily', jsonb_build_object('day', to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD'), 'streak', 29)));
create temp table d3 as select pg_temp.j(:A, $$select public.dc_daily_claim()$$) r;
select pg_temp.chk('jour 30 : 20 Boosters Premium et 10 000 crédits', (r ->> 'streak')::int = 30 and (r ->> 'prem')::int = 20 and (r ->> 'credits')::int = 10000, r::text) from d3;
select pg_temp.setp(:A, jsonb_build_object('daily', jsonb_build_object('day', to_char((now() at time zone 'Europe/Paris')::date - 1, 'YYYY-MM-DD'), 'streak', 30)));
select pg_temp.chk('après le jour 30 : retour au jour 1', (pg_temp.j(:A, $$select public.dc_daily_claim()$$) ->> 'streak')::int = 1);
select pg_temp.setp(:A, jsonb_build_object('daily', jsonb_build_object('day', '2020-01-01', 'streak', 12)));
select pg_temp.chk('jour manqué : retour au jour 1', (pg_temp.j(:A, $$select public.dc_daily_claim()$$) ->> 'streak')::int = 1);

-- ===== événements =====
select pg_temp.chk('sans événement : multiplicateur 1', public.dc__evfx(public.dc__cfg(), 'shiny') = 1);
update public.game_config set data = jsonb_set(data, '{events}', coalesce(data -> 'events', '[]') || jsonb_build_array(jsonb_build_object('k', 'essai',
  'from', to_char((now() at time zone 'Europe/Paris')::date, 'YYYY-MM-DD'), 'to', to_char((now() at time zone 'Europe/Paris')::date + 1, 'YYYY-MM-DD'),
  'fx', jsonb_build_object('shiny', 2, 'hatch', 2, 'eggs', 2, 'ec', 1.5), 'pack', jsonb_build_object('credits', 100, 'packs', 2, 'prem', 1)))) where id = 1;
select pg_temp.chk('événement : shiny ×2, éclats ×1,5', public.dc__evfx(public.dc__cfg(), 'shiny') = 2 and public.dc__evfx(public.dc__cfg(), 'ec') = 1.5);
select pg_temp.chk('événement : pas d''effet demain + 2', public.dc__evfx(public.dc__cfg(), 'shiny', to_char((now() at time zone 'Europe/Paris')::date + 2, 'YYYY-MM-DD')) = 1);
select pg_temp.setp(:A, '{"credits": 0, "bonus": 0, "spInv": {}, "evGot": {}}');
select pg_temp.t(:A, 'cadeau de l''événement', $$select public.dc_event_claim('essai')$$);
select pg_temp.chk('cadeau reçu : 100 crédits, 2 boosters, 1 Premium', (pg_temp.p(:A) ->> 'credits')::int = 100 and (pg_temp.p(:A) ->> 'bonus')::int = 2 and (pg_temp.p(:A) -> 'spInv' ->> 'prem')::int = 1);
select pg_temp.t(:A, 'cadeau une deuxième fois (ERR attendu)', $$select public.dc_event_claim('essai')$$);
select pg_temp.t(:A, 'événement inconnu (ERR attendu)', $$select public.dc_event_claim('inconnu')$$);
-- œufs deux fois plus fréquents : sur 3 000 clairières, environ deux fois plus d'œufs (Œuf et Œuf rare) qu'avant
create or replace function pg_temp.oeufs(n int) returns int language plpgsql as $f$ declare c int := 0; begin
  for i in 1 .. n loop c := c + (select count(*) from jsonb_array_elements(public.dc__lb_grid(public.dc__cfg() -> 'lumi') -> 'objs') o where o ->> 'k' in ('oeuf', 'oeufr')); end loop;
  return c; end $f$;
create temp table g_ev as select pg_temp.oeufs(3000) n;

-- ===== Pension (événement « éclosions ×2 » encore actif) =====
select pg_temp.setp(:A, jsonb_build_object('pension', jsonb_build_object('res', '{"oeuf": 1}'::jsonb)));
create temp table pn0 as select pg_temp.j(:A, $$select public.dc_pn_state()$$) r;
select pg_temp.chk('éclosions ×2 : un Œuf couve en 7 min 30', ((r -> 'pension' -> 'q' -> 0 ->> 'e')::bigint - (r -> 'pension' -> 'q' -> 0 ->> 's')::bigint) = 450000, r::text) from pn0;
update public.game_config set data = jsonb_set(data, '{events}', (select ev from ev_avant)) where id = 1;
create temp table g_sans as select pg_temp.oeufs(3000) n;
select pg_temp.chk('événement « œufs ×2 » : environ deux fois plus d''œufs', g_ev.n::numeric / greatest(g_sans.n, 1) between 1.6 and 2.4, g_ev.n || ' contre ' || g_sans.n) from g_ev, g_sans;
-- ancien format (file de 10 aux heures fixées d'avance) : prêt, en couvaison, en attente
select pg_temp.setp(:A, jsonb_build_object('pension', jsonb_build_object('res', '{"oeuf": 5, "rare": 2, "dore": 1}'::jsonb, 'q', jsonb_build_array(
  jsonb_build_object('k', 'oeuf', 's', public.dc__now() - 7200000, 'e', public.dc__now() - 3600000),
  jsonb_build_object('k', 'oeuf', 's', public.dc__now() - 300000, 'e', public.dc__now() + 600000),
  jsonb_build_object('k', 'oeuf', 's', public.dc__now() + 600000, 'e', public.dc__now() + 1500000)))));
create temp table pn1 as select pg_temp.j(:A, $$select public.dc_pn_state()$$) -> 'pension' p;
select pg_temp.chk('ancien format : 1 prêt, 3 en couvaison (l''ancien, puis le doré et un rare), le reste en réserve',
  (p -> 'rdy' ->> 'oeuf')::int = 1 and jsonb_array_length(p -> 'q') = 3 and p -> 'q' -> 1 ->> 'k' = 'dore' and p -> 'q' -> 2 ->> 'k' = 'rare'
  and (p -> 'res' ->> 'oeuf')::int = 6 and (p -> 'res' ->> 'rare')::int = 1 and not (p -> 'res' ? 'dore') and (p ->> 'v')::int = 2, p::text) from pn1;
select pg_temp.chk('heure de fin calculée (le doré en dernier, dans 1 h 30)', abs((p ->> 'end')::bigint - public.dc__now() - 5400000) < 5000, p::text) from pn1;
-- 3 heures plus tard (hors ligne) : tout est prêt, dans le bon ordre
update public.docs set data = jsonb_set(data, '{pension,q}', (select jsonb_agg(x || jsonb_build_object('s', (x ->> 's')::bigint - 10800000, 'e', (x ->> 'e')::bigint - 10800000)) from jsonb_array_elements(data -> 'pension' -> 'q') x))
  where path = 'players/11111111-1111-1111-1111-111111111111';
create temp table pn2 as select pg_temp.j(:A, $$select public.dc_pn_state()$$) -> 'pension' p;
select pg_temp.chk('3 h hors ligne : les 11 œufs sont prêts, couveuse et réserve vides',
  (p -> 'rdy' ->> 'oeuf')::int = 8 and (p -> 'rdy' ->> 'rare')::int = 2 and (p -> 'rdy' ->> 'dore')::int = 1 and jsonb_array_length(p -> 'q') = 0 and p -> 'res' = '{}' and not (p ? 'end'), p::text) from pn2;
select pg_temp.setp(:A, '{"stats": {"pnHatch": 0}}');
create temp table h1 as select pg_temp.j(:A, $$select public.dc_pn_hatch(50)$$) r;
select pg_temp.chk('éclosion groupée : 11 cartes, le doré en dernier, légendaire', jsonb_array_length(r -> 'drawn') = 11 and r -> 'drawn' -> 10 ->> 'k' = 'dore'
  and public.dc__rar(public.dc__cfg(), (r -> 'drawn' -> 10 ->> 'id')::int) in (4, 5), r -> 'drawn' ->> 10) from h1;
select pg_temp.chk('compteurs : 11 œufs éclos, 1 doré, panier vide', (pg_temp.p(:A) -> 'stats' ->> 'pnHatch')::int = 11 and (pg_temp.p(:A) -> 'stats' ->> 'pnGold')::int >= 1
  and pg_temp.p(:A) -> 'pension' -> 'rdy' = '{}');
select pg_temp.t(:A, 'éclore sans œuf prêt (ERR attendu)', $$select public.dc_pn_hatch(5)$$);
-- par 50 au plus
select pg_temp.setp(:A, jsonb_build_object('pension', jsonb_build_object('v', 2, 'rdy', '{"oeuf": 60}'::jsonb)));
select pg_temp.chk('60 œufs prêts : 50 éclosent, 10 restent', jsonb_array_length(pg_temp.j(:A, $$select public.dc_pn_hatch(500)$$) -> 'drawn') = 50 and (pg_temp.p(:A) -> 'pension' -> 'rdy' ->> 'oeuf')::int = 10);
-- mode développeur
select pg_temp.setp(:A, jsonb_build_object('dev', true, 'pension', jsonb_build_object('v', 2, 'res', '{"oeuf": 4}'::jsonb)));
select pg_temp.chk('4 œufs : 3 couvent, fin dans 30 min', jsonb_array_length(pg_temp.j(:A, $$select public.dc_pn_state()$$) -> 'pension' -> 'q') = 3
  and abs((pg_temp.p(:A) -> 'pension' ->> 'end')::bigint - public.dc__now() - 1800000) < 5000);
select pg_temp.t(:A, 'mode développeur : couvaison terminée', $$select public.dc_pn_dev()$$);
select pg_temp.chk('3 prêts, le 4e couve', (pg_temp.p(:A) -> 'pension' -> 'rdy' ->> 'oeuf')::int = 3 and jsonb_array_length(pg_temp.p(:A) -> 'pension' -> 'q') = 1);
select pg_temp.t(:B, 'mode développeur sans être administrateur (ERR attendu)', $$select public.dc_pn_dev()$$);
select pg_temp.chk('anciennes fonctions retirées', not exists (select 1 from pg_proc where proname in ('dc_pn_add', 'dc_pn_remove')));
-- un œuf qui sort en shiny n'est jamais un shiny déjà obtenu (1 sur 512 : on vérifie sur 3 000 tirages simulés)
do $$ declare cfg jsonb := public.dc__cfg(); o jsonb; sh int := 0; bad int := 0; d jsonb := '{"shiny": {"25": 1}}';
begin
  for i in 1 .. 3000 loop o := public.dc__pn_draw(d, cfg, 'oeuf'); if (o ->> 'sh')::boolean then sh := sh + 1; if d -> 'shiny' ? (o ->> 'id') then bad := bad + 1; end if; end if; end loop;
  raise notice '%', case when bad = 0 and sh < 30 then 'OK   ' else 'ERR  ' end || 'shiny des œufs : ' || sh || ' sur 3 000, aucun déjà obtenu';
end $$;

-- ===== Lumi-Bois en éclats =====
select pg_temp.setp(:A, jsonb_build_object('dev', true, 'credits', 500, 'sout', '{"ec": 10}'::jsonb, 'pension', jsonb_build_object('v', 2)));
delete from public.lumi_runs;
select pg_temp.t(:A, 'A lance une clairière (mode développeur)', $$select public.dc_lb_start()$$);
-- clairière connue : Miel 2×2 en (5,5), Œuf 2×3 en (2,5), GS Ball 2×2 en (8,5)
update public.lumi_runs set data = data || jsonb_build_object(
  'o', (select jsonb_agg(case when not public.dc__lb_play(public.dc__cfg() -> 'lumi', i % 12, i / 12) then -2
        when (i % 12) in (5,6) and (i / 12) in (5,6) then 0 when (i % 12) in (2,3) and (i / 12) in (5,6,7) then 1
        when (i % 12) in (8,9) and (i / 12) in (5,6) then 2 else -1 end order by i) from generate_series(0, 143) i),
  'l', (select jsonb_agg(false) from generate_series(1, 144)),
  'objs', '[{"k":"miel","x":5,"y":5,"w":2,"h":2,"done":false},{"k":"oeuf","x":2,"y":5,"w":2,"h":3,"done":false},{"k":"gs","x":8,"y":5,"w":2,"h":2,"done":false}]'::jsonb,
  'lamps', 2, 'used', 0);
select pg_temp.setp(:A, '{"stats": {"lbGs": "1", "lbGsX": "1"}}');
select pg_temp.t(:A, 'lanterne 1 (le Miel en entier)', $$select public.dc_lb_light(5, 6)$$);
create temp table lb1 as select pg_temp.j(:A, $$select public.dc_lb_light(2, 6)$$) r;
select pg_temp.chk('fin de clairière : gains en éclats (Miel ' || (public.dc__cfg() -> 'lumi' -> 'items' -> 'miel' ->> 'ec') || '), pas de crédits',
  (r -> 'run' -> 'res' ->> 'ec')::int = (public.dc__cfg() -> 'lumi' -> 'items' -> 'miel' ->> 'ec')::int and coalesce((r -> 'run' -> 'res' ->> 'cr')::int, 0) = 0
  and (pg_temp.p(:A) ->> 'credits')::int = 500 and (pg_temp.p(:A) -> 'sout' ->> 'ec')::int = 10 + (r -> 'run' -> 'res' ->> 'ec')::int, r -> 'run' ->> 'res') from lb1;
select pg_temp.chk('l''Œuf trouvé entre aussitôt dans la couveuse', jsonb_array_length(pg_temp.p(:A) -> 'pension' -> 'q') = 1 and pg_temp.p(:A) -> 'pension' -> 'q' -> 0 ->> 'k' = 'oeuf');

-- ===== défis du jour =====
select pg_temp.setp(:A, '{"bonus": 0, "spInv": {}, "defis": null}');
select pg_temp.t(:A, 'tirage des défis', $$select public.dc_defi_state()$$);
select pg_temp.chk('3 défis différents tirés', jsonb_array_length(pg_temp.p(:A) -> 'defis' -> 'l') = 3
  and (select count(distinct x ->> 'k') from jsonb_array_elements(pg_temp.p(:A) -> 'defis' -> 'l') x) = 3);
select pg_temp.t(:A, 'défi pas encore réussi (ERR attendu)', $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 0 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$);
select pg_temp.t(:A, 'défi qui n''est pas du jour (ERR attendu)', $$select public.dc_defi_claim('pas-un-defi')$$);
-- les trois défis réussis (compteurs avancés à la main)
update public.docs set data = jsonb_set(data, '{stats}', data -> 'stats' || (select jsonb_object_agg(x ->> 's', (x ->> 'b')::bigint + (x ->> 'need')::int) from jsonb_array_elements(data -> 'defis' -> 'l') x))
  where path = 'players/11111111-1111-1111-1111-111111111111';
create temp table df1 as select pg_temp.j(:A, $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 0 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$) r;
select pg_temp.chk('1er défi : 5 boosters', (pg_temp.p(:A) ->> 'bonus')::int = 5 and not (r ->> 'bonus')::boolean) from df1;
select pg_temp.t(:A, 'même défi deux fois (ERR attendu)', $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 0 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$);
select pg_temp.t(:A, '2e défi', $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 1 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$);
create temp table df3 as select pg_temp.j(:A, $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 2 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$) r;
select pg_temp.chk('les trois : 15 boosters et 1 Booster Premium', (r ->> 'bonus')::boolean and (pg_temp.p(:A) ->> 'bonus')::int = 15 and (pg_temp.p(:A) -> 'spInv' ->> 'prem')::int = 1) from df3;
select pg_temp.setp(:A, jsonb_build_object('defis', (pg_temp.p(:A) -> 'defis') || '{"day": "2020-01-01"}'));
select pg_temp.t(:A, 'défi d''un autre jour (ERR attendu)', $$select public.dc_defi_claim((select data -> 'defis' -> 'l' -> 0 ->> 'k' from public.docs where path = 'players/11111111-1111-1111-1111-111111111111'))$$);
select pg_temp.chk('nouveau jour : nouveaux défis', pg_temp.j(:A, $$select public.dc_defi_state()$$) -> 'profile' -> 'defis' ->> 'day' = public.dc__day());

-- ===== notifications =====
delete from public.push_subs; delete from public.push_state; delete from public.push_meta;
select pg_temp.t(:A, 'A s''abonne', $$select public.dc_push_sub('https://push.exemple/a1', repeat('x', 87), repeat('y', 22))$$);
select pg_temp.t(:A, 'abonnement invalide (ERR attendu)', $$select public.dc_push_sub('http://push.exemple/a2', repeat('x', 87), repeat('y', 22))$$);
select pg_temp.chk('rien à envoyer juste après l''abonnement', jsonb_array_length(public.dc_push_due('')) = 0);
-- boosters : la réserve vient de se remplir
select pg_temp.setp(:A, jsonb_build_object('packs', 3, 'packTs', public.dc__now() - 7 * (public.dc__cfg() ->> 'per')::bigint));
select pg_temp.chk('réserve pleine : une notification', (select count(*) from jsonb_array_elements(public.dc_push_due('')) x where x ->> 'kind' = 'packs') = 1);
select pg_temp.chk('jamais de relance', jsonb_array_length(public.dc_push_due('')) = 0);
-- œufs : tout est prêt
select pg_temp.setp(:A, jsonb_build_object('pension', jsonb_build_object('v', 2, 'end', public.dc__now())));
select pg_temp.chk('œufs prêts : une notification', (select count(*) from jsonb_array_elements(public.dc_push_due('')) x where x ->> 'kind' = 'eggs') = 1);
select pg_temp.chk('œufs : pas de relance', jsonb_array_length(public.dc_push_due('')) = 0);
-- échanges : une proposition sur une annonce (une seule notification jusqu'au retour), rien pour une annonce automatique
delete from public.docs where coll = 'market';
select pg_temp.setp(:A, '{"coll": {"16": 3, "19": 3}}');
select pg_temp.setp(:B, '{"coll": {"10": 3, "13": 3}}');
select pg_temp.t(:A, 'A met Roucool à l''échange', $$select public.dc_trade_create_many(array[16], 'any', false, null)$$);
select pg_temp.t(:A, 'A met Rattata à l''échange, acceptation automatique', $$select public.dc_trade_create_many(array[19], 'any', true, null)$$);
select pg_temp.t(:B, 'B propose sur l''annonce automatique (conclu aussitôt)', $$select public.dc_trade_propose((select substr(path, 8) from public.docs where coll = 'market' and data ->> 'card' = '19' limit 1), 13, null)$$);
select pg_temp.chk('échange automatique : pas de notification', (select trade from public.push_state where uid = '11111111-1111-1111-1111-111111111111') = 0);
select pg_temp.t(:B, 'B propose Chenipan sur Roucool', $$select public.dc_trade_propose((select substr(path, 8) from public.docs where coll = 'market' and data ->> 'card' = '16' limit 1), 10, null)$$);
select pg_temp.chk('proposition : une notification', (select count(*) from jsonb_array_elements(public.dc_push_due('')) x where x ->> 'kind' = 'trade') = 1);
select pg_temp.t(:B, 'B retire puis repropose', $$select public.dc_trade_withdraw((select substr(path, 8) from public.docs where coll = 'market' and data ->> 'card' = '16' limit 1),
  (select o.key from public.docs, jsonb_each(data -> 'offers') o where coll = 'market' and data ->> 'card' = '16' limit 1))$$);
select pg_temp.t(:B, 'B repropose', $$select public.dc_trade_propose((select substr(path, 8) from public.docs where coll = 'market' and data ->> 'card' = '16' limit 1), 10, null)$$);
select pg_temp.chk('pas de deuxième notification avant le retour de A', jsonb_array_length(public.dc_push_due('')) = 0);
select pg_temp.t(:A, 'A revient dans le jeu', $$select public.dc_push_seen()$$);
select pg_temp.chk('compteur remis à zéro', (select trade from public.push_state where uid = '11111111-1111-1111-1111-111111111111') = 0);
-- mise à jour majeure : une fois, seulement si les deux premiers nombres augmentent
select pg_temp.chk('première version lue : rien', jsonb_array_length(public.dc_push_due('1.10.0')) = 0);
select pg_temp.chk('1.10.3 : rien', jsonb_array_length(public.dc_push_due('1.10.3')) = 0);
select pg_temp.chk('1.11.0 : une notification', (select count(*) from jsonb_array_elements(public.dc_push_due('1.11.0')) x where x ->> 'kind' = 'maj') = 1);
select pg_temp.chk('1.11.0 relue : rien', jsonb_array_length(public.dc_push_due('1.11.0')) = 0);
select pg_temp.chk('1.10.9 (plus ancienne) : rien', jsonb_array_length(public.dc_push_due('1.10.9')) = 0);
select pg_temp.t(:A, 'A se désabonne', $$select public.dc_push_unsub('https://push.exemple/a1')$$);
select pg_temp.chk('plus d''abonnement', not exists (select 1 from public.push_subs));
-- droits : un joueur ne peut pas appeler les fonctions réservées au service
set role authenticated;
do $$ begin perform public.dc_push_due('1.0.0'); raise notice 'ERR  dc_push_due ouverte aux joueurs';
exception when insufficient_privilege then raise notice 'OK   dc_push_due refusée aux joueurs'; end $$;
do $$ begin perform public.dc__pn_sync('{}', '{}', 0); raise notice 'ERR  dc__pn_sync ouverte aux joueurs';
exception when insufficient_privilege then raise notice 'OK   dc__pn_sync refusée aux joueurs'; end $$;
reset role;
delete from public.docs where coll = 'market';
