-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 6 (1.5.9) : le Souterrain (fouille d'un mur, comme dans les souterrains
--  de Sinnoh). À lancer après les parties 1 à 5 et la configuration (clé sout de dexcraft-config-3.sql).
--  Le serveur arbitre tout : le mur (couches, objets, fer) est tiré et gardé ici, la page n'en voit que les cases dégagées ;
--  chaque coup de pioche ou de marteau passe par dc_sout_hit. Une partie quittée reprend où elle en était.
--  Tant que cfg.sout.open est faux, seuls les administrateurs peuvent jouer (jeu caché, mode développeur).
-- ============================================================

-- une partie par joueur (lue et écrite seulement par les fonctions ci-dessous)
create table if not exists public.sout_runs (
  uid        uuid primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.sout_runs enable row level security;
revoke all on public.sout_runs from anon, authenticated;

-- ce que la page a le droit de voir : épaisseur de chaque case, contenu des seules cases dégagées (0 vide, 'f' fer,
-- [objet, colonne, ligne] une part d'objet), objets déjà déterrés ; en fin de partie, tous les objets (ceux manqués aussi)
create or replace function public.dc__sout_view(st jsonb, d jsonb) returns jsonb language plpgsql stable as $$
declare w int; dd int[]; oo int[]; r jsonb := '[]'; i int; ob jsonb; over_ boolean;
begin
  if st is null then
    return jsonb_build_object('run', null, 'sout', coalesce(d -> 'sout', '{}'));
  end if;
  w := (st ->> 'w')::int; over_ := coalesce((st ->> 'over')::boolean, false);
  select array_agg(x::int order by n) into dd from jsonb_array_elements_text(st -> 'd') with ordinality e(x, n);
  select array_agg(x::int order by n) into oo from jsonb_array_elements_text(st -> 'o') with ordinality e(x, n);
  for i in 1 .. array_length(dd, 1) loop
    if dd[i] > 0 then r := r || 'null'::jsonb;
    elsif oo[i] = -1 then r := r || '0'::jsonb;
    elsif oo[i] = -2 then r := r || '"f"'::jsonb;
    else
      ob := st -> 'objs' -> oo[i];
      r := r || jsonb_build_array(jsonb_build_array(ob ->> 'k', (i - 1) % w - (ob ->> 'x')::int, (i - 1) / w - (ob ->> 'y')::int, oo[i]));
    end if;
  end loop;
  return jsonb_build_object('run', jsonb_build_object('w', w, 'h', st -> 'h', 'hp', st -> 'hp', 'hp0', st -> 'hp0', 'n', jsonb_array_length(st -> 'objs'),
      'd', st -> 'd', 'r', r, 'over', over_, 'end', st -> 'end', 'res', st -> 'res',
      'objs', (select coalesce(jsonb_agg(jsonb_build_object('k', x -> 'k', 'x', x -> 'x', 'y', x -> 'y', 'w', x -> 'w', 'h', x -> 'h', 'done', x -> 'done', 'i', n - 1) order by n), '[]')
               from jsonb_array_elements(st -> 'objs') with ordinality e(x, n) where over_ or coalesce((x ->> 'done')::boolean, false))),
    'sout', coalesce(d -> 'sout', '{}'));
end $$;

-- un nouveau mur : couches (base puis plaques de +1, 6 au plus), 2 à 4 objets tirés selon leur poids, 0 à 3 blocs de fer
create or replace function public.dc__sout_wall(a jsonb) returns jsonb language plpgsql volatile as $$
declare w int := (a ->> 'w')::int; h int := (a ->> 'h')::int; dd int[]; oo int[]; objs jsonb := '[]'; n int; k int; i int; j int;
  cx int; cy int; rr int; x int; y int; t int; ow int; oh int; ok boolean; tot int; r int; it record; key text; shapes int[][] := '{{1,1},{2,1},{1,2},{2,2},{3,1}}';
begin
  dd := array_fill((a ->> 'base')::int, array[w * h]); oo := array_fill(-1, array[w * h]);
  for k in 1 .. (a ->> 'plaq')::int loop
    cx := public.dc__rnd(w); cy := public.dc__rnd(h); rr := 1 + public.dc__rnd(3);
    for y in 0 .. h - 1 loop for x in 0 .. w - 1 loop
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= rr * rr then dd[y * w + x + 1] := least(6, dd[y * w + x + 1] + 1); end if;
    end loop; end loop;
  end loop;
  select sum((v ->> 'w')::int) into tot from jsonb_each(a -> 'items') e(k, v);
  n := (a -> 'n' ->> 0)::int + public.dc__rnd((a -> 'n' ->> 1)::int - (a -> 'n' ->> 0)::int + 1);
  -- objets, puis fer (-2) ; un objet qui ne trouve pas de place après 200 essais est abandonné
  for i in 1 .. n + (a -> 'irons' ->> 0)::int + public.dc__rnd((a -> 'irons' ->> 1)::int - (a -> 'irons' ->> 0)::int + 1) loop
    if i <= n then
      r := public.dc__rnd(tot); key := null;
      for it in select e.k, e.v from jsonb_each(a -> 'items') e(k, v) order by e.k loop
        r := r - (it.v ->> 'w')::int;
        if r < 0 then key := it.k; ow := (it.v -> 's' ->> 0)::int; oh := (it.v -> 's' ->> 1)::int; exit; end if;
      end loop;
    else
      key := null; t := public.dc__rnd(5) + 1; ow := shapes[t][1]; oh := shapes[t][2];
    end if;
    for t in 1 .. 200 loop
      x := public.dc__rnd(w - ow + 1); y := public.dc__rnd(h - oh + 1); ok := true;
      for j in 0 .. ow * oh - 1 loop
        if oo[(y + j / ow) * w + x + j % ow + 1] <> -1 then ok := false; exit; end if;
      end loop;
      if ok then
        for j in 0 .. ow * oh - 1 loop
          oo[(y + j / ow) * w + x + j % ow + 1] := case when key is null then -2 else jsonb_array_length(objs) end;
        end loop;
        if key is not null then objs := objs || jsonb_build_object('k', key, 'x', x, 'y', y, 'w', ow, 'h', oh, 'done', false); end if;
        exit;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('w', w, 'h', h, 'd', to_jsonb(dd), 'o', to_jsonb(oo), 'objs', objs, 'hp', (a ->> 'hp')::int, 'hp0', (a ->> 'hp')::int,
    'over', false, 'ir', 0, 't', public.dc__now());
end $$;

-- état : la partie en cours (ou la dernière, finie) et le sac du joueur
create or replace function public.dc_sout_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); st jsonb;
begin
  select data into st from public.sout_runs where uid = u;
  return public.dc__sout_view(st, d);
end $$;

-- nouvelle partie : une partie pas finie est reprise telle quelle, sinon le mur coûte cfg.sout.cost crédits
-- (gratuit pour l'administrateur en mode développeur, comme les boosters)
create or replace function public.dc_sout_start() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); a jsonb := public.dc__cfg() -> 'sout'; st jsonb; cost bigint;
begin
  if a is null then raise exception 'Le Souterrain n’est pas encore ouvert.'; end if;
  if not coalesce((a ->> 'open')::boolean, false) and not public.dc__is_admin(u) then raise exception 'Le Souterrain n’est pas encore ouvert.'; end if;
  select data into st from public.sout_runs where uid = u for update;
  if st is not null and not coalesce((st ->> 'over')::boolean, false) then return public.dc__sout_view(st, d) || jsonb_build_object('profile', d); end if;
  cost := case when public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false) then 0 else (a ->> 'cost')::bigint end;
  if public.dc__int(d, 'credits') < cost then raise exception 'Il vous faut % crédits pour fouiller un mur.', cost; end if;
  d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - cost));
  st := public.dc__sout_wall(a);
  insert into public.sout_runs (uid, data) values (u, st) on conflict (uid) do update set data = excluded.data, updated_at = now();
  d := public.dc__save(u, public.dc__bump(d, 'souRuns'));
  return public.dc__sout_view(st, d) || jsonb_build_object('profile', d);
end $$;

-- fin de partie (mur effondré ou tout déterré) : sphères en éclats, pièces et billets en crédits, statistiques des titres
create or replace function public.dc__sout_end(u uuid, st jsonb, a jsonb) returns jsonb language plpgsql volatile as $$
declare d jsonb := public.dc__lock(u, true); ob jsonb; it jsonb; ec bigint := 0; cr bigint := 0; nd int := 0; got jsonb; so jsonb; items jsonb := '[]';
begin
  so := case when jsonb_typeof(d -> 'sout') = 'object' then d -> 'sout' else '{}' end;
  got := case when jsonb_typeof(so -> 'got') = 'object' then so -> 'got' else '{}' end;
  for ob in select x from jsonb_array_elements(st -> 'objs') x where coalesce((x ->> 'done')::boolean, false) loop
    it := a -> 'items' -> (ob ->> 'k'); nd := nd + 1; items := items || to_jsonb(ob ->> 'k');
    ec := ec + coalesce((it ->> 'v')::int, 0); cr := cr + coalesce((it ->> 'cr')::int, 0);
    got := got || jsonb_build_object(ob ->> 'k', coalesce((got ->> (ob ->> 'k'))::int, 0) + 1);
    if ob ->> 'k' = 'or' then d := public.dc__bump(d, 'souOr'); end if;
    if ob ->> 'k' = 'gd' then d := jsonb_set(d, '{stats,souGd}', '1'); end if;
  end loop;
  if nd > 0 then d := public.dc__bump(d, 'souItems', nd); end if;
  if (st ->> 'ir')::int > 0 then d := public.dc__bump(d, 'souIron', (st ->> 'ir')::int); end if;
  -- titre « Rien ne m'échappe » : un mur à 4 objets entièrement vidé
  if nd = 4 and jsonb_array_length(st -> 'objs') = 4 then d := jsonb_set(d, '{stats,souFull}', '1'); end if;
  d := d || jsonb_build_object('credits', public.dc__int(d, 'credits') + cr,
    'sout', so || jsonb_build_object('ec', coalesce((so ->> 'ec')::bigint, 0) + ec, 'got', got));
  st := st || jsonb_build_object('over', true, 'res', jsonb_build_object('ec', ec, 'cr', cr, 'items', items));
  update public.sout_runs set data = st, updated_at = now() where uid = u;
  return jsonb_build_object('st', st, 'd', public.dc__save(u, d));
end $$;

-- un coup : p_tool 'p' (pioche : −2 couches sur la case) ou 'h' (marteau : −2 au centre, −1 sur la croix).
-- Fissure : pick ou hammer points, doublés si le centre du coup est un bloc de fer (« cling »).
-- Ne lit ni ne verrouille le profil, sauf à la fin de la partie.
create or replace function public.dc_sout_hit(p_x int, p_y int, p_tool text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); a jsonb; st jsonb; w int; h int; dd int[]; oo int[]; objs jsonb; c int; iron boolean; dmg int;
  q int[]; x int; y int; i int; j int; ob jsonb; fresh jsonb := '[]'; all_ boolean := true; e jsonb; d jsonb; hp int;
begin
  if p_tool not in ('p', 'h') then raise exception 'Outil inconnu.'; end if;
  select data into st from public.sout_runs where uid = u for update;
  if st is null or coalesce((st ->> 'over')::boolean, false) then raise exception 'Aucune fouille en cours.'; end if;
  w := (st ->> 'w')::int; h := (st ->> 'h')::int;
  if p_x is null or p_y is null or p_x < 0 or p_y < 0 or p_x >= w or p_y >= h then raise exception 'Case invalide.'; end if;
  a := public.dc__cfg() -> 'sout';
  select array_agg(v::int order by n) into dd from jsonb_array_elements_text(st -> 'd') with ordinality t(v, n);
  select array_agg(v::int order by n) into oo from jsonb_array_elements_text(st -> 'o') with ordinality t(v, n);
  c := p_y * w + p_x + 1; iron := oo[c] = -2;
  dmg := (a ->> case when p_tool = 'h' then 'hammer' else 'pick' end)::int * case when iron then 2 else 1 end;
  dd[c] := dd[c] - 2;
  if p_tool = 'h' then
    foreach q slice 1 in array array[[-1,0],[1,0],[0,-1],[0,1]] loop
      x := p_x + q[1]; y := p_y + q[2];
      if x >= 0 and y >= 0 and x < w and y < h then dd[y * w + x + 1] := dd[y * w + x + 1] - 1; end if;
    end loop;
  end if;
  -- objets entièrement dégagés par ce coup
  objs := st -> 'objs';
  for i in 0 .. jsonb_array_length(objs) - 1 loop
    ob := objs -> i;
    if coalesce((ob ->> 'done')::boolean, false) then continue; end if;
    if not exists (select 1 from generate_series(0, (ob ->> 'w')::int * (ob ->> 'h')::int - 1) k
                   where dd[((ob ->> 'y')::int + k / (ob ->> 'w')::int) * w + (ob ->> 'x')::int + k % (ob ->> 'w')::int + 1] > 0) then
      objs := jsonb_set(objs, array[i::text, 'done'], 'true'); fresh := fresh || to_jsonb(i);
    else all_ := false; end if;
  end loop;
  hp := greatest(0, (st ->> 'hp')::int - dmg);
  st := st || jsonb_build_object('d', to_jsonb(dd), 'objs', objs, 'hp', hp, 'ir', (st ->> 'ir')::int + case when iron then 1 else 0 end);
  if hp <= 0 or all_ then
    st := st || jsonb_build_object('end', case when all_ then 'all' else 'wall' end);
    e := public.dc__sout_end(u, st, a); st := e -> 'st'; d := e -> 'd';
    return public.dc__sout_view(st, d) || jsonb_build_object('profile', d, 'iron', iron, 'fresh', fresh, 'dmg', dmg);
  end if;
  update public.sout_runs set data = st, updated_at = now() where uid = u;
  return public.dc__sout_view(st, null) - 'sout' || jsonb_build_object('iron', iron, 'fresh', fresh, 'dmg', dmg);
end $$;

-- comptoir : les éclats contre des lots (boosters dans la réserve achetée, boosters spéciaux dans l'inventaire)
create or replace function public.dc_sout_buy(p_lot text, p_val int default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); lot jsonb; so jsonb; ec bigint; k text; inv jsonb;
begin
  select x into lot from jsonb_array_elements(cfg -> 'sout' -> 'lots') x where x ->> 'k' = p_lot;
  if lot is null then raise exception 'Lot inconnu.'; end if;
  so := case when jsonb_typeof(d -> 'sout') = 'object' then d -> 'sout' else '{}' end;
  ec := coalesce((so ->> 'ec')::bigint, 0);
  if ec < (lot ->> 'p')::bigint then raise exception 'Il vous manque % éclats.', (lot ->> 'p')::bigint - ec; end if;
  d := d || jsonb_build_object('sout', so || jsonb_build_object('ec', ec - (lot ->> 'p')::bigint));
  if lot ? 'packs' then
    d := jsonb_set(d, '{bonus}', to_jsonb(public.dc__int(d, 'bonus') + (lot ->> 'packs')::int));
  else
    k := public.dc__sp_key(cfg, lot ->> 'sp', p_val);
    inv := case when jsonb_typeof(d -> 'spInv') = 'object' then d -> 'spInv' else '{}' end;
    d := d || jsonb_build_object('spInv', inv || jsonb_build_object(k, coalesce((inv ->> k)::int, 0) + 1));
  end if;
  return jsonb_build_object('profile', public.dc__save(u, d));
end $$;

-- ============================================================
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dc\_\_sout\_%' or p.proname like 'dc\_sout\_%') loop
    execute format('revoke all on function %s from public, anon%s', f.sig, case when f.proname like 'dc\_\_%' then ', authenticated' else '' end);
    if f.proname not like 'dc\_\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 6 OK' as verif, (select count(*) from pg_proc where proname like 'dc_sout_%') as fonctions_souterrain;
