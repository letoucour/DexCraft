-- ============================================================
--  Test général : toutes les actions d'un joueur (boosters, évolutions, échanges, jeux, prestige…), sur une base de test
--  neuve (outils/tester-sql.ps1). Chaque ligne commence par OK ou ERR ; « (ERR attendu) » : l'erreur est voulue.
-- ============================================================
\set ON_ERROR_STOP 0
\pset footer off
insert into auth.users values ('11111111-1111-1111-1111-111111111111','a@t'),('22222222-2222-2222-2222-222222222222','b@t') on conflict do nothing;
insert into public.admins values ('11111111-1111-1111-1111-111111111111') on conflict do nothing;
create or replace function pg_temp.t(who text, step text, q text) returns text language plpgsql as $f$
declare r jsonb; begin
  perform set_config('request.jwt.claim.sub', who, false);
  execute q into r;
  return 'OK   ' || step;
exception when others then return 'ERR  ' || step || ' : ' || sqlerrm;
end $f$;
\set A '''11111111-1111-1111-1111-111111111111'''
\set B '''22222222-2222-2222-2222-222222222222'''
select pg_temp.t(:A,'A init', $$select public.dc_init()$$);
select pg_temp.t(:B,'B init', $$select public.dc_init()$$);
select pg_temp.t(:A,'A pseudo', $$select public.dc_set_pseudo('Testeur A')$$);
select pg_temp.t(:B,'B pseudo', $$select public.dc_set_pseudo('Testeur B')$$);
select pg_temp.t(:A,'A récompense du jour', $$select public.dc_daily_claim()$$);
update public.docs set data = data || '{"bonus": 40}' where path = 'players/11111111-1111-1111-1111-111111111111'; -- assez de boosters pour la suite
select pg_temp.t(:A,'A ouvre 10', $$select public.dc_open(10)$$);
select pg_temp.t(:A,'A ouvre 10 (2)', $$select public.dc_open(10)$$);
select pg_temp.t(:B,'B ouvre 10', $$select public.dc_open(10)$$);
select pg_temp.t(:A,'A achète 5 boosters', $$select public.dc_buy_packs(5)$$);
select pg_temp.t(:A,'A pack lancement', $$select public.dc_buy_once('lancement')$$);
select pg_temp.t(:A,'A booster spécial acheté', $$select public.dc_buy_special('gen',4,1)$$);
select pg_temp.t(:A,'A booster spécial ouvert', $$select public.dc_open_special('gen',4,1)$$);
update public.docs set data = jsonb_set(jsonb_set(data, '{coll,1}', '4'), '{coll,4}', '5') where path = 'players/11111111-1111-1111-1111-111111111111'; -- de quoi faire évoluer
select pg_temp.t(:A,'A évolution rapide', $$select public.dc_quick_evo(false)$$);
update public.docs set data = jsonb_set(data, '{coll,7}', '5') where path = 'players/11111111-1111-1111-1111-111111111111';
select pg_temp.t(:A,'A tout faire évoluer', $$select public.dc_quick_evo(true)$$);
select pg_temp.t(:A,'A favori', $$select public.dc_toggle_fav((select k::int from public.docs, jsonb_object_keys(data->'coll') k where path='players/11111111-1111-1111-1111-111111111111' limit 1))$$);
select pg_temp.t(:A,'A cloche', $$select public.dc_toggle_wish(150)$$);
select pg_temp.t(:A,'A image', $$select public.dc_set_avatar((select k::int from public.docs, jsonb_object_keys(data->'coll') k where path='players/11111111-1111-1111-1111-111111111111' limit 1), false)$$);
select pg_temp.t(:A,'A vitrine', $$select public.dc_set_vitrine((select jsonb_agg(jsonb_build_object('i',k::int)) from (select k from public.docs, jsonb_object_keys(data->'coll') k where path='players/11111111-1111-1111-1111-111111111111' limit 2) z))$$);
select pg_temp.t(:A,'A défausse doubles', $$select public.dc_discard((select jsonb_object_agg(k, (v::int)-1) from public.docs, jsonb_each_text(data->'coll') e(k,v) where path='players/11111111-1111-1111-1111-111111111111' and v::int>1 and k::int<2000))$$);
select pg_temp.t(:A,'A met 3 cartes à l''échange', $$select public.dc_trade_create_many((select array_agg(k::int) from (select k from public.docs, jsonb_each_text(data->'coll') e(k,v) where path='players/11111111-1111-1111-1111-111111111111' and k::int<2000 order by k limit 3) z),'any',false,null)$$);
select pg_temp.t(:B,'B propose une carte', $$select public.dc_trade_propose(
  (select substr(path, 8) from public.docs where coll='market' order by path limit 1),
  (select k::int from public.docs, jsonb_each_text(data->'coll') e(k,v) where path='players/22222222-2222-2222-2222-222222222222'
     and public.dc__rar(public.dc__cfg(), k::int) = (select public.dc__rar(public.dc__cfg(), (data->>'card')::int) from public.docs where coll='market' order by path limit 1) limit 1), null)$$);
select pg_temp.t(:A,'A accepte', $$select public.dc_trade_answer((select substr(path, 8) from public.docs where coll='market' order by path limit 1),
  (select o.key from public.docs, jsonb_each(data->'offers') o where coll='market' order by path limit 1), true)$$);
select 'échanges conclus' info, count(*) from public.trade_log;
select pg_temp.t(:A,'A retire une annonce', $$select public.dc_trade_cancel((select substr(path, 8) from public.docs where coll='market' order by path desc limit 1))$$);
select pg_temp.t(:A,'A VoltoBataille état', $$select public.dc_vb_state()$$);
select pg_temp.t(:A,'A VoltoBataille carte', $$select public.dc_vb_flip(0)$$);
select pg_temp.t(:A,'A VoltoBataille quitte (ERR attendu si la carte retournée vaut 1 : rien à encaisser)', $$select public.dc_vb_quit()$$);
select pg_temp.t(:A,'A Arène départ', $$select public.dc_ar_start(true)$$);
select pg_temp.t(:A,'A Arène relance', $$select public.dc_ar_reroll(null,null)$$);
select pg_temp.t(:A,'A Arène achat', $$select public.dc_ar_buy(0,null,null)$$);
select pg_temp.t(:A,'A Arène verrou', $$select public.dc_ar_lock(true,null,null)$$);
select pg_temp.t(:A,'A Arène combat', $$select public.dc_ar_fight(null,null)$$);
select pg_temp.t(:A,'A Arène suite', $$select public.dc_ar_next(null,null)$$);
select pg_temp.t(:A,'A Arène état', $$select public.dc_ar_state()$$);
select pg_temp.t(:A,'A Souterrain départ', $$select public.dc_sout_start()$$);
select pg_temp.t(:A,'A Souterrain coup', $$select public.dc_sout_hit(5,5,'h')$$);
select pg_temp.t(:A,'A Souterrain état', $$select public.dc_sout_state()$$);
select pg_temp.t(:A,'A titres', $$select public.dc_set_titles('[]')$$);
select pg_temp.t(:A,'A astuce', $$select public.dc_tip_done('booster')$$);
select pg_temp.t(:A,'A look', $$select public.dc_set_look('dos', null)$$);
select pg_temp.t(:A,'A shiny vue', $$select public.dc_shiny_view(null)$$);
select pg_temp.t(:A,'A code inconnu', $$select public.dc_redeem_code('XYZINCONNU')$$);
select pg_temp.t(:A,'A cartes secrètes', $$select to_jsonb(public.dc_secret_cards(null))$$);
select pg_temp.t(:A,'A marché depuis', $$select to_jsonb(r) from public.dc_market_since(now() - interval '1 hour') r limit 1$$);
select pg_temp.t(:A,'A admin don', $$select public.dc_admin_grant('22222222-2222-2222-2222-222222222222', 100, 2)$$);
select pg_temp.t(:B,'B cadeau ouvert', $$select public.dc_gift_open()$$);
select pg_temp.t(:B,'B admin (ERR attendu)', $$select public.dc_admin_grant('22222222-2222-2222-2222-222222222222', 100, 2)$$);
select pg_temp.t(:A,'A défausse mythique (ERR attendu)', $$select public.dc_discard('{"2001":1}')$$);
-- prestige : A reçoit tout le Pokédex puis passe au prestige 1
update public.docs set data = jsonb_set(data, '{coll}', (data->'coll') || (select jsonb_object_agg(x, 1) from jsonb_array_elements_text(public.dc__cfg()->'dexOrder') x)) where path='players/11111111-1111-1111-1111-111111111111';
select pg_temp.t(:A,'A prestige', $$select public.dc_prestige()$$);
select summary->>'pseudo' pseudo, summary->>'prestige' prestige, summary->>'packs' packs, summary->>'unique' uniq, data->'stats'->>'trades' echanges from public.docs where coll='players' order by 1;
