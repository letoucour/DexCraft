-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 7 (1.8.0 ; gains en éclats et Pension automatique depuis la 1.10.0) : Lumi-Bois (clairière à éclairer à la lanterne, inspirée du Crystal
--  Sphere de Slay the Spire 2) et Pension (œufs à faire couver puis éclore). À lancer après les parties 1 à 6 et la
--  configuration (clés lumi et pension de dexcraft-config-3.sql).
--  Le serveur arbitre tout : la clairière (objets, piège) est tirée et gardée ici, la page ne voit que les cases éclairées ;
--  le Pokémon d'un œuf n'est tiré qu'à son éclosion. Une partie quittée reprend où elle en était.
--  Tant que cfg.lumi.open (cfg.pension.open) est faux, seuls les administrateurs peuvent jouer (mode développeur).
-- ============================================================

create table if not exists public.lumi_runs (
  uid        uuid primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.lumi_runs enable row level security;
revoke all on public.lumi_runs from anon, authenticated;

-- case (x, y) jouable : clairière de 12 × 12 aux coins en escalier, largeur de chaque ligne dans a.rows (centrée)
create or replace function public.dc__lb_play(a jsonb, x int, y int) returns boolean language sql immutable as $$
  select y >= 0 and y < (a ->> 'h')::int and x >= 0 and x < (a ->> 'w')::int
     and x >= ((a ->> 'w')::int - (a -> 'rows' ->> y)::int) / 2 and x < ((a ->> 'w')::int + (a -> 'rows' ->> y)::int) / 2 $$;

-- ce que la page a le droit de voir : pour chaque case, null (dans le noir), 0 (éclairée et vide), 'x' (hors de la clairière),
-- ou [objet affiché, colonne, ligne, n° de l'objet] ; un piège pas encore entièrement éclairé se montre sous l'objet qu'il
-- imite (look) ; en fin de partie, tous les objets
create or replace function public.dc__lb_view(st jsonb, d jsonb) returns jsonb language plpgsql stable as $$
declare a jsonb := public.dc__cfg() -> 'lumi'; w int; h int; oo int[]; li boolean[]; r jsonb := '[]'; i int; ob jsonb; over_ boolean; k text;
begin
  if st is null then return jsonb_build_object('run', null, 'lumi', coalesce(d -> 'lumi', '{}')); end if;
  w := (st ->> 'w')::int; h := (st ->> 'h')::int; over_ := coalesce((st ->> 'over')::boolean, false);
  select array_agg(x::int order by n) into oo from jsonb_array_elements_text(st -> 'o') with ordinality e(x, n);
  select array_agg(x::boolean order by n) into li from jsonb_array_elements_text(st -> 'l') with ordinality e(x, n);
  for i in 1 .. w * h loop
    if oo[i] = -2 then r := r || '"x"'::jsonb;
    elsif not li[i] then r := r || 'null'::jsonb;
    elsif oo[i] = -1 then r := r || '0'::jsonb;
    else
      ob := st -> 'objs' -> oo[i]; k := ob ->> 'k';
      if not coalesce((ob ->> 'done')::boolean, false) and (a -> 'items' -> k) ? 'look' then k := a -> 'items' -> k ->> 'look'; end if;
      r := r || jsonb_build_array(jsonb_build_array(k, (i - 1) % w - (ob ->> 'x')::int, (i - 1) / w - (ob ->> 'y')::int, oo[i]));
    end if;
  end loop;
  return jsonb_build_object('run', jsonb_build_object('w', w, 'h', h, 'lamps', st -> 'lamps', 'used', st -> 'used', 'n', jsonb_array_length(st -> 'objs'),
      'r', r, 'over', over_, 'res', st -> 'res', 'ev', st -> 'ev',
      'objs', (select coalesce(jsonb_agg(jsonb_build_object('k', x -> 'k', 'x', x -> 'x', 'y', x -> 'y', 'w', x -> 'w', 'h', x -> 'h', 'm', x -> 'm', 'done', x -> 'done', 'i', n - 1) order by n), '[]')
               from jsonb_array_elements(st -> 'objs') with ordinality e(x, n) where over_ or coalesce((x ->> 'done')::boolean, false))),
    'lumi', coalesce(d -> 'lumi', '{}'));
end $$;

-- une nouvelle clairière : n objets tirés selon leur poids (un seul piège au plus), posés sur des cases jouables
create or replace function public.dc__lb_grid(a jsonb) returns jsonb language plpgsql volatile as $$
declare w int := (a ->> 'w')::int; h int := (a ->> 'h')::int; oo int[]; objs jsonb := '[]'; n int; i int; j int; t int; x int; y int;
  tot int; r int; it record; key text; mk text; ow int; oh int; ok boolean; trap boolean := false; px int; py int;
  em numeric := public.dc__evfx(public.dc__cfg(), 'eggs');   -- événement : œufs plus fréquents (1.10.0)
begin
  oo := array_fill(-1, array[w * h]);
  for y in 0 .. h - 1 loop for x in 0 .. w - 1 loop
    if not public.dc__lb_play(a, x, y) then oo[y * w + x + 1] := -2; end if;
  end loop; end loop;
  select sum(round((v ->> 'w')::int * case when v ? 'egg' then em else 1 end)::int) into tot from jsonb_each(a -> 'items') e(k, v);
  n := (a -> 'n' ->> 0)::int + public.dc__rnd((a -> 'n' ->> 1)::int - (a -> 'n' ->> 0)::int + 1);
  for i in 1 .. n loop
    loop
      r := public.dc__rnd(tot); key := null;
      for it in select e.k, e.v from jsonb_each(a -> 'items') e(k, v) order by e.k loop
        r := r - round((it.v ->> 'w')::int * case when it.v ? 'egg' then em else 1 end)::int;
        if r < 0 then key := it.k; ow := (it.v -> 's' ->> 0)::int; oh := (it.v -> 's' ->> 1)::int; mk := it.v ->> 'm'; exit; end if;
      end loop;
      exit when not ((a -> 'items' -> key) ? 'trap' and trap);   -- un seul piège par clairière
    end loop;
    for t in 1 .. 200 loop
      x := public.dc__rnd(w - ow + 1); y := public.dc__rnd(h - oh + 1); ok := true;
      for j in 0 .. ow * oh - 1 loop
        px := x + j % ow; py := y + j / ow;
        if (mk is null or substr(mk, j + 1, 1) = '1') and oo[py * w + px + 1] <> -1 then ok := false; exit; end if;
      end loop;
      if ok then
        for j in 0 .. ow * oh - 1 loop
          if mk is null or substr(mk, j + 1, 1) = '1' then oo[(y + j / ow) * w + x + j % ow + 1] := jsonb_array_length(objs); end if;
        end loop;
        objs := objs || jsonb_build_array(jsonb_build_object('k', key, 'x', x, 'y', y, 'w', ow, 'h', oh, 'done', false)
          || case when mk is not null then jsonb_build_object('m', mk) else '{}' end);
        if (a -> 'items' -> key) ? 'trap' then trap := true; end if;
        exit;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('w', w, 'h', h, 'o', to_jsonb(oo), 'l', to_jsonb(array_fill(false, array[w * h])), 'objs', objs,
    'lamps', (a ->> 'lamps')::int, 'used', 0, 'over', false, 't', public.dc__now());
end $$;

create or replace function public.dc_lb_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); st jsonb;
begin
  select data into st from public.lumi_runs where uid = u;
  return public.dc__lb_view(st, d);
end $$;

-- nouvelle clairière : une partie pas finie est reprise, sinon elle coûte cfg.lumi.cost crédits (gratuit en mode développeur)
create or replace function public.dc_lb_start() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); a jsonb := public.dc__cfg() -> 'lumi'; st jsonb; cost bigint;
begin
  if a is null or not coalesce((a ->> 'open')::boolean, false) and not public.dc__is_admin(u) then raise exception 'Lumi-Bois n’est pas encore ouvert.'; end if;
  select data into st from public.lumi_runs where uid = u for update;
  if st is not null and not coalesce((st ->> 'over')::boolean, false) then return public.dc__lb_view(st, d) || jsonb_build_object('profile', d); end if;
  cost := case when public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false) then 0 else (a ->> 'cost')::bigint end;
  if public.dc__int(d, 'credits') < cost then raise exception 'Il vous faut % crédits pour explorer une clairière.', cost; end if;
  d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - cost));
  st := public.dc__lb_grid(a);
  insert into public.lumi_runs (uid, data) values (u, st) on conflict (uid) do update set data = excluded.data, updated_at = now();
  d := public.dc__save(u, public.dc__bump(d, 'lbRuns'));
  return public.dc__lb_view(st, d) || jsonb_build_object('profile', d);
end $$;

-- fin de partie : éclats (1.10.0, demande de Theo : avant, des crédits ; même solde que le Souterrain, sout.ec), Pierres évolutives (stock du Souterrain, sout.ps), œufs (réserve de la Pension), GS Ball,
-- trouvailles (lumi.got) et statistiques des titres
create or replace function public.dc__lb_end(u uuid, st jsonb, a jsonb) returns jsonb language plpgsql volatile as $$
declare d jsonb := public.dc__lock(u, true); ob jsonb; it jsonb; k text; ec bigint := 0; cr bigint := 0; nd int := 0; nm int := 0; nb int := 0; lu jsonb; got jsonb;
  so jsonb; pn jsonb; res jsonb; items jsonb := '[]'; clear boolean := true; ne jsonb := '{}'; cfg jsonb := public.dc__cfg(); now_ bigint := public.dc__now();
begin
  lu := case when jsonb_typeof(d -> 'lumi') = 'object' then d -> 'lumi' else '{}' end;
  got := case when jsonb_typeof(lu -> 'got') = 'object' then lu -> 'got' else '{}' end;
  so := case when jsonb_typeof(d -> 'sout') = 'object' then d -> 'sout' else '{}' end;
  pn := case when jsonb_typeof(d -> 'pension') = 'object' then d -> 'pension' else '{}' end;
  for ob in select x from jsonb_array_elements(st -> 'objs') x loop
    k := ob ->> 'k'; it := a -> 'items' -> k;
    if not coalesce((ob ->> 'done')::boolean, false) then
      if not it ? 'trap' then clear := false; end if;
      continue;
    end if;
    got := got || jsonb_build_object(k, coalesce((got ->> k)::int, 0) + 1);
    if it ? 'trap' then continue; end if;
    nd := nd + 1;
    if it ? 'mush' then nm := nm + 1; end if;
    if it ? 'lamp' then nb := nb + 1; end if;
    if it ? 'stone' then so := so || jsonb_build_object('ps', coalesce((so ->> 'ps')::int, 0) + 1); end if;
    if it ? 'egg' then ne := ne || jsonb_build_object(it ->> 'egg', coalesce((ne ->> (it ->> 'egg'))::int, 0) + 1); end if;
    if k = 'oeufd' then d := jsonb_set(d, '{stats,lbGold}', '1'); end if;
    if it ? 'gs' then   -- GS Ball : la première donne le titre « Hors du Temps » ; une fois la carte obtenue (lbGsX), elle vaut it.gs éclats
      if coalesce(d -> 'stats' ->> 'lbGs', '') = '' then d := jsonb_set(d, '{stats,lbGs}', '1'); lu := lu || '{"gs": 1}'; items := items || '"gs"';
      elsif coalesce(d -> 'stats' ->> 'lbGsX', '') <> '' then ec := ec + (it ->> 'gs')::int; items := items || '"gs+"';
      else items := items || '"gs"'; end if;
      continue;
    end if;
    ec := ec + coalesce((it ->> 'ec')::int, 0); cr := cr + coalesce((it ->> 'cr')::int, 0); items := items || to_jsonb(k);   -- cr : Perle et Pépite (1.10.1)
  end loop;
  if nd > 0 then d := public.dc__bump(d, 'lbItems', nd); end if;
  if nm > 0 then d := public.dc__bump(d, 'lbMush', nm); end if;
  if nb > 0 then d := public.dc__bump(d, 'lbBocal', nb); end if;
  if coalesce((st ->> 'trap')::boolean, false) then d := public.dc__bump(d, 'lbTrap'); end if;
  if clear then d := jsonb_set(d, '{stats,lbClear}', '1'); end if;
  ec := round(ec * public.dc__evfx(cfg, 'ec'));   -- événement « éclats »
  so := so || jsonb_build_object('ec', coalesce((so ->> 'ec')::bigint, 0) + ec);
  -- œufs : la couveuse est mise à l'heure avec l'ancienne réserve, puis prend aussitôt les nouveaux s'il y a de la place (1.10.0)
  pn := public.dc__pn_sync(pn, cfg, now_); res := pn -> 'res';
  for k in select key from jsonb_each(ne) loop res := res || jsonb_build_object(k, coalesce((res ->> k)::int, 0) + (ne ->> k)::int); end loop;
  pn := public.dc__pn_sync(pn || jsonb_build_object('res', res), cfg, now_);
  d := d || jsonb_build_object('lumi', lu || jsonb_build_object('got', got), 'sout', so, 'pension', pn, 'credits', public.dc__int(d, 'credits') + cr);
  st := st || jsonb_build_object('over', true, 'res', jsonb_build_object('ec', ec, 'cr', cr, 'items', items));
  update public.lumi_runs set data = st, updated_at = now() where uid = u;
  return jsonb_build_object('st', st, 'd', public.dc__save(u, d));
end $$;

-- une lanterne : éclaire le carré de 3 × 3 autour de la case (p_x, p_y), qui doit être dans la clairière. Objets entièrement
-- éclairés : gagnés ; Bocal de lucioles : +1 lanterne ; piège (Amonita) : −1 lanterne. Fin : plus de lanterne, ou tous les
-- objets trouvés (piège excepté). Ne verrouille le profil qu'à la fin.
create or replace function public.dc_lb_light(p_x int, p_y int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); a jsonb := public.dc__cfg() -> 'lumi'; st jsonb; w int; h int; oo int[]; li boolean[]; objs jsonb; ob jsonb;
  i int; dx int; dy int; lamps int; fresh jsonb := '[]'; ev jsonb := '[]'; it jsonb; e jsonb; allf boolean;
begin
  select data into st from public.lumi_runs where uid = u for update;
  if st is null or coalesce((st ->> 'over')::boolean, false) then raise exception 'Aucune clairière en cours.'; end if;
  w := (st ->> 'w')::int; h := (st ->> 'h')::int; lamps := (st ->> 'lamps')::int;
  if lamps < 1 then raise exception 'Plus de lanterne.'; end if;
  if p_x is null or p_y is null or not public.dc__lb_play(a, p_x, p_y) then raise exception 'Case hors de la clairière.'; end if;
  select array_agg(x::int order by n) into oo from jsonb_array_elements_text(st -> 'o') with ordinality q(x, n);
  select array_agg(x::boolean order by n) into li from jsonb_array_elements_text(st -> 'l') with ordinality q(x, n);
  for dy in -1 .. 1 loop for dx in -1 .. 1 loop
    if public.dc__lb_play(a, p_x + dx, p_y + dy) then li[(p_y + dy) * w + p_x + dx + 1] := true; end if;
  end loop; end loop;
  lamps := lamps - 1; objs := st -> 'objs';
  for i in 0 .. jsonb_array_length(objs) - 1 loop
    ob := objs -> i;
    continue when coalesce((ob ->> 'done')::boolean, false);
    select bool_and(li[k]) into allf from generate_series(1, w * h) k where oo[k] = i;
    if allf then
      objs := jsonb_set(objs, array[i::text, 'done'], 'true'); fresh := fresh || to_jsonb(i); it := a -> 'items' -> (ob ->> 'k');
      if it ? 'lamp' then lamps := lamps + 1; ev := ev || '"lamp"'; end if;
      if it ? 'trap' then lamps := greatest(0, lamps - 1); ev := ev || '"trap"'; st := st || '{"trap": true}'; end if;
    end if;
  end loop;
  st := st || jsonb_build_object('l', to_jsonb(li), 'objs', objs, 'lamps', lamps, 'used', coalesce((st ->> 'used')::int, 0) + 1, 'ev', ev);
  if lamps = 0 or not exists (select 1 from jsonb_array_elements(objs) x where not coalesce((x ->> 'done')::boolean, false) and not (a -> 'items' -> (x ->> 'k')) ? 'trap') then
    e := public.dc__lb_end(u, st, a);
    return public.dc__lb_view(e -> 'st', e -> 'd') || jsonb_build_object('profile', e -> 'd', 'fresh', fresh);
  end if;
  update public.lumi_runs set data = st, updated_at = now() where uid = u;
  return public.dc__lb_view(st, '{}'::jsonb) - 'lumi' || jsonb_build_object('fresh', fresh);
end $$;

-- ============================================================
--  Pension (1.10.0, demande de Theo : les œufs s'entassaient dans la réserve). pension.res : réserve {oeuf, rare, dore}, sans
--  limite ; pension.q : œufs en couvaison ({k, s, e}, cfg.pension.slots au plus, 3) ; pension.rdy : œufs prêts à éclore {k: nombre},
--  sans limite ; pension.end : heure à laquelle tous les œufs seront prêts (notification). La couveuse se remplit toute seule depuis
--  la réserve, dans l'ordre doré, rare, normal : dès qu'une place se libère, l'œuf suivant y entre, même hors ligne. Rien ne change
--  entre deux actions du joueur sauf le temps : chaque fonction refait le calcul jusqu'à maintenant (dc__pn_sync) avant d'agir.
-- ============================================================
-- Ancien format (1.8.0 à 1.9.3 : file de 10 œufs aux heures fixées d'avance, sans pension.v) : les œufs prêts vont dans rdy, ceux qui
-- couvent gardent leur place, ceux qui attendaient retournent dans la réserve. Durée d'un œuf : cfg.pension.dur, divisée par l'effet
-- « hatch » des événements du jour où il entre dans la couveuse.
create or replace function public.dc__pn_sync(pn jsonb, cfg jsonb, now_ bigint) returns jsonb language plpgsql stable as $$
declare a jsonb := cfg -> 'pension'; n int := coalesce((a ->> 'slots')::int, 3); res jsonb; rdy jsonb; x jsonb; ks text[] := array['dore', 'rare', 'oeuf'];
  sk text[] := '{}'; ss bigint[] := '{}'; se bigint[] := '{}'; m int; f bigint; k text; legacy boolean; q jsonb := '[]'; endt bigint; rc jsonb; INF bigint := 9000000000000000;
begin
  pn := case when jsonb_typeof(pn) = 'object' then pn else '{}' end;
  legacy := coalesce((pn ->> 'v')::int, 0) < 2;
  res := case when jsonb_typeof(pn -> 'res') = 'object' then pn -> 'res' else '{}' end;
  rdy := case when jsonb_typeof(pn -> 'rdy') = 'object' then pn -> 'rdy' else '{}' end;
  for x in select v from jsonb_array_elements(case when jsonb_typeof(pn -> 'q') = 'array' then pn -> 'q' else '[]' end) v loop
    k := x ->> 'k';
    if legacy and (x ->> 'e')::bigint <= now_ then rdy := rdy || jsonb_build_object(k, coalesce((rdy ->> k)::int, 0) + 1);
    elsif legacy and (x ->> 's')::bigint > now_ or coalesce(array_length(sk, 1), 0) >= n then res := res || jsonb_build_object(k, coalesce((res ->> k)::int, 0) + 1);
    else sk := sk || k; ss := ss || (x ->> 's')::bigint; se := se || (x ->> 'e')::bigint; end if;
  end loop;
  while coalesce(array_length(sk, 1), 0) < n loop sk := sk || null::text; ss := ss || 0::bigint; se := se || now_; end loop;
  -- jusqu'à maintenant : chaque place libérée (œuf terminé, ou place vide) prend l'œuf suivant de la réserve à ce moment-là
  loop
    select i into m from generate_subscripts(se, 1) i where se[i] <= now_ order by se[i], i limit 1;
    exit when m is null;
    f := se[m];
    if sk[m] is not null then rdy := rdy || jsonb_build_object(sk[m], coalesce((rdy ->> sk[m])::int, 0) + 1); sk[m] := null; end if;
    k := (select z from unnest(ks) with ordinality t(z, o) where coalesce((res ->> z)::int, 0) > 0 order by o limit 1);
    if k is null then se[m] := INF; continue; end if;
    res := res || jsonb_build_object(k, (res ->> k)::int - 1);
    sk[m] := k; ss[m] := f;
    se[m] := f + round((a -> 'dur' ->> k)::numeric / public.dc__evfx(cfg, 'hatch', to_char(to_timestamp(f / 1000.0) at time zone 'Europe/Paris', 'YYYY-MM-DD')))::bigint;
  end loop;
  for m in 1 .. n loop
    if sk[m] is not null then q := q || jsonb_build_object('k', sk[m], 's', ss[m], 'e', se[m]); end if;
  end loop;
  -- heure à laquelle tout sera prêt : la suite du même calcul avec la réserve actuelle (pour les notifications)
  rc := res;
  loop
    select i into m from generate_subscripts(se, 1) i where se[i] < INF order by se[i], i limit 1;
    exit when m is null;
    k := (select z from unnest(ks) with ordinality t(z, o) where coalesce((rc ->> z)::int, 0) > 0 order by o limit 1);
    if k is null then endt := greatest(coalesce(endt, 0), se[m]); se[m] := INF; continue; end if;
    rc := rc || jsonb_build_object(k, (rc ->> k)::int - 1);
    se[m] := se[m] + round((a -> 'dur' ->> k)::numeric / public.dc__evfx(cfg, 'hatch', to_char(to_timestamp(se[m] / 1000.0) at time zone 'Europe/Paris', 'YYYY-MM-DD')))::bigint;
  end loop;
  res := (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(res) where value::text <> '0');
  rdy := (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(rdy) where value::text <> '0');
  return (pn - 'end') || jsonb_build_object('v', 2, 'q', q, 'res', res, 'rdy', rdy) || case when endt is not null then jsonb_build_object('end', endt) else '{}' end;
end $$;

-- état de la Pension (et heure du serveur) : la couveuse est remise à l'heure et enregistrée si elle a changé
create or replace function public.dc_pn_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); pn jsonb; now_ bigint := public.dc__now();
begin
  pn := public.dc__pn_sync(d -> 'pension', public.dc__cfg(), now_);
  if pn is distinct from d -> 'pension' then
    d := public.dc__save(u, d || jsonb_build_object('pension', pn));
    return jsonb_build_object('pension', pn, 'now', now_, 'profile', d);
  end if;
  return jsonb_build_object('pension', pn, 'now', now_);
end $$;

-- mode développeur (administrateur) : les œufs en couvaison sont prêts tout de suite, les suivants entrent dans la couveuse
create or replace function public.dc_pn_dev() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); pn jsonb; now_ bigint := public.dc__now();
begin
  if not (public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false)) then raise exception 'Réservé au mode développeur.'; end if;
  pn := public.dc__pn_sync(d -> 'pension', cfg, now_);
  pn := jsonb_set(pn, '{q}', (select coalesce(jsonb_agg(x || jsonb_build_object('e', now_)), '[]') from jsonb_array_elements(pn -> 'q') x));
  d := d || jsonb_build_object('pension', public.dc__pn_sync(pn, cfg, now_));
  return jsonb_build_object('profile', public.dc__save(u, d), 'now', now_);
end $$;

-- Pokémon d'un œuf (1.8.2, demande de Theo) : 'oeuf' = n'importe quel Pokémon Commun ou Peu commun, ou un premier stade d'évolution
-- (aucune évolution n'y mène) Rare ou Épique, jamais légendaire, raretés aux chances d'un booster ; 'rare' = Rare, Épique, Méga et Gigamax
-- ou Légendaire aux chances cfg.pension.rareW (40 / 30 / 20 / 10 % depuis la 1.8.3) ; 'dore' = un Légendaire (réserve des Légendaires des boosters).
-- Jamais de mythique, transcendante ni spéciale. Shiny : 1 sur cfg.pension.shiny, sans rencontres ni Charme Chroma, et
-- toujours un shiny que le joueur n'a pas encore (sinon pas de shiny).
create or replace function public.dc__pn_draw(d jsonb, cfg jsonb, p_k text) returns jsonb language plpgsql volatile as $$
declare pools jsonb := '[]'; pool jsonb; odds bigint[] := '{}'; tot bigint := 0; r int; x bigint; id int; sh boolean; tg jsonb; c jsonb;
begin
  if p_k = 'oeuf' then select coalesce(jsonb_agg(distinct v), '[]') into tg from jsonb_each(cfg -> 'evo') e, jsonb_array_elements(e.value) v; end if;
  for r in 0 .. 5 loop
    pool := coalesce(cfg -> 'pool' -> (r::text), cfg -> 'byr' -> r);
    if p_k = 'dore' and r <> 5 or p_k = 'oeuf' and r >= 5 then pool := '[]';
    elsif p_k = 'oeuf' and r >= 2 then pool := (select coalesce(jsonb_agg(v), '[]') from jsonb_array_elements(pool) v where not tg @> jsonb_build_array(v));
    end if;
    pools := pools || jsonb_build_array(pool);
    odds := odds || case when jsonb_array_length(pool) = 0 then 0::bigint
      when p_k = 'rare' then coalesce((cfg -> 'pension' -> 'rareW' ->> r)::bigint, 0) else (cfg -> 'oddsK' ->> r)::bigint end;
    tot := tot + odds[r + 1];
  end loop;
  x := public.dc__rnd(tot::int); r := 0;
  for i in 0 .. 5 loop
    if x < odds[i + 1] then r := i; exit; end if;
    x := x - odds[i + 1];
  end loop;
  pool := pools -> r;
  sh := public.dc__rnd((cfg -> 'pension' ->> 'shiny')::int) < greatest(1, round(public.dc__evfx(cfg, 'shiny')))::int;   -- × événement (1.10.0)
  if sh then
    c := (select coalesce(jsonb_agg(v), '[]') from jsonb_array_elements(pool) v
          where not coalesce(d -> 'shiny', '{}') ? (v #>> '{}') and not coalesce(cfg -> 'shinyNo', '[]') @> jsonb_build_array(v));
    if jsonb_array_length(c) > 0 then pool := c; else sh := false; end if;
  end if;
  id := (pool ->> public.dc__rnd(jsonb_array_length(pool)))::int;
  return jsonb_build_object('id', id, 'sh', sh, 'r', r);
end $$;

-- éclosion (1.10.0) : jusqu'à p_n œufs prêts d'un coup (50 au plus), les plus précieux d'abord ; chaque Pokémon n'est tiré qu'à ce
-- moment-là. Les cartes sont renvoyées dans l'ordre normal, rare, doré (les meilleures à la fin de la main).
drop function if exists public.dc_pn_hatch(int, boolean);
drop function if exists public.dc_pn_add(text);
drop function if exists public.dc_pn_remove(int);
create or replace function public.dc_pn_hatch(p_n int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); pn jsonb; rdy jsonb; o jsonb; id int; k text;
  drawn jsonb := '[]'; now_ bigint := public.dc__now(); left_ int := least(greatest(coalesce(p_n, 1), 1), 50); nh int := 0; ng int := 0;
begin
  if not coalesce((cfg -> 'pension' ->> 'open')::boolean, false) and not public.dc__is_admin(u) then raise exception 'La Pension n’est pas encore ouverte.'; end if;
  pn := public.dc__pn_sync(d -> 'pension', cfg, now_); rdy := pn -> 'rdy';
  foreach k in array array['dore', 'rare', 'oeuf'] loop
    while left_ > 0 and coalesce((rdy ->> k)::int, 0) > 0 loop
      rdy := rdy || jsonb_build_object(k, (rdy ->> k)::int - 1); left_ := left_ - 1;
      o := public.dc__pn_draw(d, cfg, k); id := (o ->> 'id')::int;
      drawn := jsonb_build_array(jsonb_build_object('id', id, 'isNew', public.dc__count(d, id) = 0, 'shiny', (o ->> 'sh')::boolean, 'k', k)) || drawn;
      if (o ->> 'sh')::boolean then
        d := jsonb_set(jsonb_set(d, '{shiny}', coalesce(d -> 'shiny', '{}') || jsonb_build_object(id::text, now_)), '{stats,pnShiny}', '1');
      end if;
      d := public.dc__gain(d, id, 1); nh := nh + 1;
      if k = 'dore' then ng := ng + 1; end if;
    end loop;
  end loop;
  if nh = 0 then raise exception 'Aucun œuf n’est prêt à éclore.'; end if;
  pn := pn || jsonb_build_object('rdy', (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(rdy) where value::text <> '0'));
  d := public.dc__bump(d || jsonb_build_object('pension', pn), 'pnHatch', nh);
  if ng > 0 then d := public.dc__bump(d, 'pnGold', ng); end if;
  return jsonb_build_object('profile', public.dc__save(u, d), 'drawn', drawn, 'now', now_);
end $$;

-- ============================================================
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dc\_\_lb\_%' or p.proname like 'dc\_lb\_%' or p.proname like 'dc\_\_pn\_%' or p.proname like 'dc\_pn\_%') loop
    execute format('revoke all on function %s from public, anon%s', f.sig, case when f.proname like 'dc\_\_%' then ', authenticated' else '' end);
    if f.proname not like 'dc\_\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 7 OK' as verif, (select count(*) from pg_proc where proname like 'dc_lb_%' or proname like 'dc_pn_%') as fonctions_lumi_pension;
