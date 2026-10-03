-- ============================================================
--  Tests de la 1.10.1 : Perle et Pépite de Lumi-Bois, versées en crédits (les autres objets en éclats).
--  Base de test locale seulement (outils/tester-sql.ps1). Chaque ligne commence par OK ou ERR.
-- ============================================================
\set ON_ERROR_STOP 0
\pset footer off
\pset tuples_only on
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
\set A '''11111111-1111-1111-1111-111111111111'''
select pg_temp.t(:A, 'A init', $$select public.dc_init()$$);
update public.docs set data = data || '{"dev": true, "credits": 500, "sout": {"ec": 0}}' where path = 'players/11111111-1111-1111-1111-111111111111';
delete from public.lumi_runs;
select pg_temp.t(:A, 'A lance une clairière', $$select public.dc_lb_start()$$);
-- Perle en (5,5), Pépite en (6,5), Miel 2×2 en (5,6) : une lanterne en (5,6) éclaire tout ; un Noigrume caché ailleurs garde la partie ouverte
update public.lumi_runs set data = data || jsonb_build_object(
  'o', (select jsonb_agg(case when not public.dc__lb_play(public.dc__cfg() -> 'lumi', i % 12, i / 12) then -2
        when i = 5 * 12 + 5 then 0 when i = 5 * 12 + 6 then 1 when (i % 12) in (5,6) and (i / 12) in (6,7) then 2 when i = 10 * 12 + 2 then 3 else -1 end order by i) from generate_series(0, 143) i),
  'l', (select jsonb_agg(false) from generate_series(1, 144)),
  'objs', '[{"k":"perle","x":5,"y":5,"w":1,"h":1,"done":false},{"k":"pepite","x":6,"y":5,"w":1,"h":1,"done":false},{"k":"miel","x":5,"y":6,"w":2,"h":2,"done":false},{"k":"noig","x":2,"y":10,"w":1,"h":1,"done":false}]'::jsonb,
  'lamps', 1, 'used', 0);
create temp table r1 as select pg_temp.j(:A, $$select public.dc_lb_light(5, 6)$$) r;
select pg_temp.chk('Perle et Pépite en crédits, Miel en éclats',
  (r -> 'run' -> 'res' ->> 'cr')::int = (public.dc__cfg() -> 'lumi' -> 'items' -> 'perle' ->> 'cr')::int + (public.dc__cfg() -> 'lumi' -> 'items' -> 'pepite' ->> 'cr')::int
  and (r -> 'run' -> 'res' ->> 'ec')::int = (public.dc__cfg() -> 'lumi' -> 'items' -> 'miel' ->> 'ec')::int, r -> 'run' ->> 'res') from r1;
select pg_temp.chk('crédits et éclats versés au profil', (data ->> 'credits')::int = 500 + 55 and (data -> 'sout' ->> 'ec')::int = (public.dc__cfg() -> 'lumi' -> 'items' -> 'miel' ->> 'ec')::int, data ->> 'credits')
  from public.docs where path = 'players/11111111-1111-1111-1111-111111111111';
