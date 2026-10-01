-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 5 (1.3.0) : l'Arène (combat automatique façon Teamfight Tactics, simplifié).
--  À lancer après les parties 1 à 4 et la configuration (3 fichiers : dexcraft-config-3.sql porte les données de l'Arène).
--  Le serveur arbitre tout : boutique tirée dans la collection du joueur, or, évolutions, adversaires, combat et crédits.
--  La page ne fait qu'afficher la partie et animer le déroulé du combat renvoyé par dc_ar_fight.
-- ============================================================

-- une partie en cours par joueur (lue et écrite seulement par les fonctions ci-dessous)
create table if not exists public.ar_runs (
  uid        uuid primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.ar_runs enable row level security;
revoke all on public.ar_runs from anon, authenticated;

-- ---------- données d'un Pokémon (1 à 1025), lues dans la configuration ----------
create or replace function public.dc__ar_stat(sc text, id int) returns int[] language sql immutable as $$
  select array_agg((position(substr(sc, (id - 1) * 12 + k * 2 + 1, 1) in '0123456789abcdefghijklmnopqrstuvwxyz') - 1) * 36
    + position(substr(sc, (id - 1) * 12 + k * 2 + 2, 1) in '0123456789abcdefghijklmnopqrstuvwxyz') - 1 order by k)
  from generate_series(0, 5) k $$;
create or replace function public.dc__ar_types(pt text, id int) returns int[] language sql immutable as $$
  select array_remove(array[ascii(substr(pt, 2 * id - 1, 1)) - 96,
    case when substr(pt, 2 * id, 1) = '-' then null else ascii(substr(pt, 2 * id, 1)) - 96 end], null) $$;
-- multiplicateur de dégâts : meilleur type de l'attaquant, cumulé sur les types du défenseur
create or replace function public.dc__ar_mult(ch text, a int[], dd int[]) returns numeric language plpgsql immutable as $$
declare best numeric := 0; m numeric; x int; y int;
begin
  foreach x in array a loop
    m := 1;
    foreach y in array dd loop
      m := m * case substr(ch, (x - 1) * 18 + y, 1) when '2' then 2 when 'h' then .5 when '0' then 0 else 1 end;
    end loop;
    best := greatest(best, m);
  end loop;
  return best;
end $$;
create or replace function public.dc__ar_rar(cfg jsonb, id int) returns int language sql immutable as $$ select (cfg -> 'rar' ->> id::text)::int $$;
create or replace function public.dc__ar_cost(cfg jsonb, id int) returns int language sql immutable as $$
  select (cfg -> 'arena' -> 'cost' ->> public.dc__ar_rar(cfg, id)::text)::int $$;
-- 1.4.0 (demande de Theo) : dans l'Arène, Bargantua (550) joue la forme Motif Blanc, la seule qui évolue en Paragruel (902)
create or replace function public.dc__ar_evo(cfg jsonb, id int) returns int[] language sql immutable as $$
  select case when id = 550 then '{902}'::int[] else
    (select coalesce(array_agg(x::int), '{}') from jsonb_array_elements_text(coalesce(cfg -> 'evo' -> id::text, '[]')) x where x::int <= 1025) end $$;
-- coefficient des statistiques selon les étoiles (starK) ; deux étoiles selon la rareté depuis la 1.4.12 (star2, demande de Theo)
create or replace function public.dc__ar_stark(cfg jsonb, id int, s int) returns numeric language sql immutable as $$
  select coalesce(case when s = 2 then (cfg -> 'arena' -> 'star2' ->> public.dc__ar_rar(cfg, id)::text)::numeric end,
                  (cfg -> 'arena' -> 'starK' ->> s)::numeric, 1) $$;
create or replace function public.dc__ar_max(r int) returns int language sql immutable as $$ select least(6, 3 + (r - 1) / 2) $$;
-- rareté tirée selon la manche, parmi les raretés qui ont au moins un Pokémon (avail : 5 booléens) ; une ligne de odds par
-- manche depuis la 1.4.7 (table de Theo), par bandes de 2 manches avant (5 lignes) ; au-delà de la dernière ligne, la dernière
create or replace function public.dc__ar_pick_rar(cfg jsonb, r int, avail boolean[]) returns int language plpgsql volatile as $$
declare n int := jsonb_array_length(cfg -> 'arena' -> 'odds');
  o jsonb := cfg -> 'arena' -> 'odds' -> least(n - 1, case when n > 5 then r - 1 else (r - 1) / 2 end); w int[] := '{}'; s int := 0; x int; k int; rs int[] := array[0, 1, 2, 3, 5];
begin
  for k in 1 .. 5 loop w := w || case when avail[k] then (o ->> (k - 1))::int else 0 end; s := s + w[k]; end loop;
  if s = 0 then return -1; end if;
  x := floor(random() * s);
  for k in 1 .. 5 loop if x < w[k] then return rs[k]; end if; x := x - w[k]; end loop;
  return rs[1];
end $$;

-- ---------- unités : {u: numéro, i: Pokémon, s: 1 si étoile}, sur le terrain (6 cases) et le banc (8 cases) ----------
create or replace function public.dc__ar_units(st jsonb) returns setof jsonb language sql immutable as $$
  select v from jsonb_array_elements(st -> 'board') v where v <> 'null'
  union all select v from jsonb_array_elements(st -> 'bench') v where v <> 'null' $$;

-- 3 exemplaires du même Pokémon : il évolue (au hasard s'il y a plusieurs évolutions), ou gagne une étoile en fin de lignée
create or replace function public.dc__ar_merge(cfg jsonb, st jsonb, id int) returns jsonb language plpgsql volatile as $$
declare pos text[]; evo int[]; nid int;
begin
  loop
    select array_agg(z || ':' || k order by z = 'board' desc, k) into pos from (
      select 'board' z, k - 1 k from jsonb_array_elements(st -> 'board') with ordinality e(v, k) where v <> 'null' and (v ->> 'i')::int = id and (v ->> 's')::int = 0
      union all
      select 'bench', k - 1 from jsonb_array_elements(st -> 'bench') with ordinality e(v, k) where v <> 'null' and (v ->> 'i')::int = id and (v ->> 's')::int = 0) s;
    exit when coalesce(array_length(pos, 1), 0) < 3;
    st := jsonb_set(st, array[split_part(pos[2], ':', 1), split_part(pos[2], ':', 2)], 'null');
    st := jsonb_set(st, array[split_part(pos[3], ':', 1), split_part(pos[3], ':', 2)], 'null');
    evo := public.dc__ar_evo(cfg, id);
    if coalesce(array_length(evo, 1), 0) > 0 then
      nid := evo[1 + floor(random() * array_length(evo, 1))::int];
      st := jsonb_set(st, array[split_part(pos[1], ':', 1), split_part(pos[1], ':', 2), 'i'], to_jsonb(nid));
      st := st || jsonb_build_object('msg', 'evo:' || id || ':' || nid);
      id := nid;
    else
      st := jsonb_set(st, array[split_part(pos[1], ':', 1), split_part(pos[1], ':', 2), 's'], '1');
      st := st || jsonb_build_object('msg', 'star:' || id);
      exit;
    end if;
  end loop;
  -- 1.4.0 (Arène v3.0, demande de Theo) : 3 exemplaires à une étoile du même Pokémon donnent 2 étoiles
  select array_agg(z || ':' || k order by z = 'board' desc, k) into pos from (
    select 'board' z, k - 1 k from jsonb_array_elements(st -> 'board') with ordinality e(v, k) where v <> 'null' and (v ->> 'i')::int = id and (v ->> 's')::int = 1
    union all
    select 'bench', k - 1 from jsonb_array_elements(st -> 'bench') with ordinality e(v, k) where v <> 'null' and (v ->> 'i')::int = id and (v ->> 's')::int = 1) s;
  if coalesce(array_length(pos, 1), 0) >= 3 then
    st := jsonb_set(st, array[split_part(pos[2], ':', 1), split_part(pos[2], ':', 2)], 'null');
    st := jsonb_set(st, array[split_part(pos[3], ':', 1), split_part(pos[3], ':', 2)], 'null');
    st := jsonb_set(st, array[split_part(pos[1], ':', 1), split_part(pos[1], ':', 2), 's'], '2');
    st := st || jsonb_build_object('msg', 'star2:' || id);
  end if;
  return st;
end $$;

-- ---------- boutique : 5 Pokémon de la collection du joueur ----------
-- chaque case a une chance (slot) de reproposer un Pokémon de l'équipe (pour réunir 3 exemplaires) ; sinon rareté selon la
-- manche, puis un Pokémon de cette rareté, les types joués par l'équipe pesant plus lourd (typeW, en part de la réserve)
create or replace function public.dc__ar_shop(cfg jsonb, st jsonb, coll jsonb) returns jsonb language plpgsql volatile as $$
-- 1.3.1 : réserve lue une seule fois dans des tableaux (rareté et poids de chaque Pokémon possédé). Avant, la table des
-- raretés de la configuration était recopiée à chaque Pokémon examiné : plusieurs secondes par boutique sur Supabase.
declare a jsonb := cfg -> 'arena'; rarm jsonb := cfg -> 'rar'; pt text := cfg ->> 'ptype'; tc int[] := array_fill(0, array[18]);
  ids int[]; rs int[]; ws numeric[]; mine int[]; cnt int[] := array[0, 0, 0, 0, 0, 0]; av boolean[]; shop jsonb := '[]';
  k int; j int; r int; t int; u jsonb; wt numeric; tot numeric; x numeric; pick int; slot numeric := (a ->> 'slot')::numeric;
begin
  for u in select * from public.dc__ar_units(st) loop
    foreach t in array public.dc__ar_types(pt, (u ->> 'i')::int) loop tc[t] := tc[t] + 1; end loop;
  end loop;
  -- réserve : Pokémon 1 à 1025 de la collection, leur rareté, et combien de Pokémon de l'équipe partagent un de leurs types
  select coalesce(array_agg(o order by o), '{}'), coalesce(array_agg(q.rr order by o), '{}'),
         coalesce(array_agg(least(6, tc[t1] + coalesce(tc[t2], 0)) order by o), '{}')
    into ids, rs, ws
    from (select key::int o, (rarm ->> key)::int rr, ascii(substr(pt, 2 * key::int - 1, 1)) - 96 t1,
                 case when substr(pt, 2 * key::int, 1) = '-' then null else ascii(substr(pt, 2 * key::int, 1)) - 96 end t2
          from jsonb_each(coll) where key ~ '^\d+$' and key::int between 1 and 1025 and value::text::int > 0) q;
  for j in 1 .. coalesce(array_length(ids, 1), 0) loop cnt[rs[j] + 1] := cnt[rs[j] + 1] + 1; end loop;   -- nombre par rareté (0 à 5)
  av := array[cnt[1] > 0, cnt[2] > 0, cnt[3] > 0, cnt[4] > 0, cnt[6] > 0];
  -- 1.4.7 (demande de Theo) : les Pokémon à une étoile sont aussi reproposés (à demi-taux jusqu’à la 1.4.8), pour qu'on puisse
  -- viser les deux étoiles ; avant, un Pokémon passé à une étoile ne revenait plus qu'au hasard de toute la réserve
  -- 1.4.9 : un tirage par Pokémon différent (plus par exemplaire), une étoile au même taux : un Pokémon à une étoile, seule
  -- unité parmi une dizaine et à demi-taux, ne revenait que dans 7 % des boutiques (mesuré, équipe de 10) ; slot 0,2 → 0,3
  select coalesce(array_agg(distinct (v ->> 'i')::int), '{}') into mine
    from public.dc__ar_units(st) v where (v ->> 's')::int <= 1 and (v ->> 'i')::int = any(ids);
  for k in 1 .. 5 loop
    if coalesce(array_length(mine, 1), 0) > 0 and random() < slot then
      shop := shop || to_jsonb(mine[1 + floor(random() * array_length(mine, 1))::int]); continue;
    end if;
    r := public.dc__ar_pick_rar(cfg, (st ->> 'round')::int, av);
    if r < 0 then shop := shop || 'null'::jsonb; continue; end if;
    wt := greatest(.3, cnt[r + 1] * (a ->> 'typeW')::numeric);
    tot := 0;
    for j in 1 .. array_length(ids, 1) loop if rs[j] = r then tot := tot + 1 + ws[j] * wt; end if; end loop;
    x := random() * tot; pick := null;
    for j in 1 .. array_length(ids, 1) loop
      if rs[j] = r then x := x - (1 + ws[j] * wt); pick := ids[j]; exit when x < 0; end if;
    end loop;
    shop := shop || to_jsonb(pick);
  end loop;
  return shop;
end $$;

-- ---------- équipe de l'ordinateur ----------
create or replace function public.dc__ar_enemy(cfg jsonb, st jsonb) returns jsonb language plpgsql volatile as $$
declare a jsonb := cfg -> 'arena'; rd int := (st ->> 'round')::int; n int := public.dc__ar_max(rd); team jsonb := '[]';
  av boolean[]; r int; id int; e int; evo int[]; nu int := (st ->> 'n')::int; board jsonb := '[null,null,null,null,null,null]'; u jsonb; k int := 0;
  -- 1.4.0 (demande de Theo) : rareté la plus haute de l'adversaire selon la manche (évolutions comprises) :
  -- manches 1 et 2 Peu commune, 3 Rare, 4 à 6 Épique, ensuite tout
  maxr int := case when rd <= 2 then 1 when rd = 3 then 2 when rd <= 6 then 3 else 5 end; pw numeric; c int;
  -- 1.4.7 (demande de Theo) : équipe à thème : le type du premier Pokémon est le thème (60 % des suivants), un second type
  -- vient du premier Pokémon hors thème (25 %), le reste au hasard (les exceptions)
  pt text := cfg ->> 'ptype'; t1 int; t2 int; want int; rx numeric; tys int[];
begin
  select array_agg(jsonb_array_length(coalesce(cfg -> 'arBase' -> rr::text, '[]')) > 0 and rr <= maxr order by ord) into av from unnest(array[0, 1, 2, 3, 5]) with ordinality x(rr, ord);
  for k in 1 .. n loop
    r := public.dc__ar_pick_rar(cfg, rd + 1, av); if r < 0 then r := 0; end if;
    rx := random(); want := case when t1 is null then null when rx < .6 then t1 when rx < .85 then t2 else null end; id := null;
    if want is not null then   -- de la rareté tirée si possible, sinon d'une rareté plus basse
      select v::int into id from unnest(array[0, 1, 2, 3, 5]) rr, jsonb_array_elements_text(coalesce(cfg -> 'arBase' -> rr::text, '[]')) v
        where rr <= r and (ascii(substr(pt, 2 * v::int - 1, 1)) - 96 = want or ascii(substr(pt, 2 * v::int, 1)) - 96 = want)
        order by rr = r desc, rr desc, random() limit 1;
    end if;
    if id is null then
      id := (cfg -> 'arBase' -> r::text ->> floor(random() * jsonb_array_length(cfg -> 'arBase' -> r::text))::int)::int;
      tys := public.dc__ar_types(pt, id);
      if t1 is null then t1 := tys[1 + floor(random() * array_length(tys, 1))::int];
      elsif t2 is null and not (t1 = any(tys)) then t2 := tys[1 + floor(random() * array_length(tys, 1))::int]; end if;
    end if;
    for e in 1 .. 2 loop
      if random() < least(.8, (a ->> 'aiEvo')::numeric * rd) then
        evo := public.dc__ar_evo(cfg, id);
        if coalesce(array_length(evo, 1), 0) > 0 then
          c := evo[1 + floor(random() * array_length(evo, 1))::int];
          if public.dc__ar_rar(cfg, c) <= maxr then id := c; end if;
        end if;
      end if;
    end loop;
    nu := nu + 1;
    team := team || jsonb_build_object('u', nu, 'i', id, 's', case when rd >= 7 and random() < .08 * (rd - 6) then 1 else 0 end);
  end loop;
  k := 0;   -- les plus résistants (Défense) devant
  for u in select v from jsonb_array_elements(team) v order by (public.dc__ar_stat(cfg ->> 'arStat', (v ->> 'i')::int))[3] desc loop
    board := jsonb_set(board, array[k::text], u); k := k + 1;
  end loop;
  -- puissance (1.4.0) : un peu moins en manches 1 et 2 (aiEarly), un peu plus à partir de la 5e (aiLate par manche) et
  -- surtout à la dernière (aiLast), où les joueurs ont dépensé toute leur économie
  pw := (a ->> 'aiPow0')::numeric + (a ->> 'aiPowK')::numeric * rd
    - case when rd <= 2 then coalesce((a ->> 'aiEarly')::numeric, 0) else 0 end
    + greatest(0, rd - 4) * coalesce((a ->> 'aiLate')::numeric, 0)
    + case when rd >= (a ->> 'rounds')::int then coalesce((a ->> 'aiLast')::numeric, 0) else 0 end;
  return jsonb_build_object('board', board, 'power', pw, 'n', nu);
end $$;

-- ---------- nouvelle manche : adversaire, et boutique sauf si elle est verrouillée ----------
-- boutique de la manche suivante (pshop : en attente) ; verrouillée : gardée pour cette manche seulement, puis déverrouillée
-- d'office (1.3.15, demande de Theo). 1.5.15 : après un combat, elle ne change qu'à la fin de l'animation (dc_ar_next), pour
-- qu'on puisse acheter et relancer pendant le combat dans la boutique d'avant (demande de Theo)
create or replace function public.dc__ar_pshop(cfg jsonb, st jsonb, coll jsonb) returns jsonb language plpgsql volatile as $$
begin
  if not coalesce((st ->> 'pshop')::boolean, false) then return st; end if;
  st := st - 'pshop';
  if not coalesce((st ->> 'locked')::boolean, false) then st := jsonb_set(st, '{shop}', public.dc__ar_shop(cfg, st, coll));
  else st := jsonb_set(st, '{locked}', 'false'); end if;
  return st;
end $$;
create or replace function public.dc__ar_round(cfg jsonb, st jsonb, coll jsonb) returns jsonb language plpgsql volatile as $$
declare e jsonb;
begin
  e := public.dc__ar_enemy(cfg, st);
  st := st || jsonb_build_object('enemy', jsonb_build_object('board', e -> 'board', 'power', e -> 'power'), 'n', e -> 'n', 'pshop', true);
  return st;
end $$;

-- vue renvoyée à la page : la partie, et les crédits déjà gagnés aujourd'hui dans l'Arène (1.5.5 : cagnotte de la partie en cours comprise)
create or replace function public.dc__ar_view(d jsonb, st jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('run', st - 'msg', 'msg', st -> 'msg',
    'gained', case when d -> 'arena' ->> 'day' = public.dc__day() then public.dc__int(d -> 'arena', 'gained') else 0 end
      + case when coalesce((st ->> 'over')::boolean, false) then 0 else coalesce((st ->> 'pend')::int, 0) end,
    'cap', public.dc__cfg() -> 'arena' -> 'cap') $$;

create or replace function public.dc_ar_state() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); st jsonb;
begin
  select data into st from public.ar_runs where uid = u for update;
  -- boutique en attente (page fermée pendant un combat) : posée maintenant
  if coalesce((st ->> 'pshop')::boolean, false) and not coalesce((st ->> 'over')::boolean, false) then
    st := public.dc__ar_pshop(public.dc__cfg(), st, d -> 'coll'); perform public.dc__ar_put(u, st);
  end if;
  return public.dc__ar_view(d, st);
end $$;

-- fin de l'animation d'un combat (1.5.15) : la boutique de la nouvelle manche
create or replace function public.dc_ar_next(p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); st jsonb := public.dc__ar_get(u);
begin
  st := public.dc__ar_pshop(public.dc__cfg(), public.dc__ar_layout(st, p_board, p_bench) - 'msg', d -> 'coll');
  perform public.dc__ar_put(u, st);
  return public.dc__ar_view(d, st);
end $$;

-- nouvelle partie (p_new : abandonner celle en cours)
create or replace function public.dc_ar_start(p_new boolean default false) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); a jsonb := cfg -> 'arena'; st jsonb;
begin
  if a is null then raise exception 'L’Arène n’est pas encore ouverte.'; end if;
  select data into st from public.ar_runs where uid = u for update;
  if st is not null and not coalesce((st ->> 'over')::boolean, false) and not p_new then return public.dc__ar_view(d, st); end if;
  -- 1.5.5 : partie abandonnée, sa cagnotte est versée comme à la fin d'une partie
  if st is not null and not coalesce((st ->> 'over')::boolean, false) and coalesce((st ->> 'pend')::int, 0) + coalesce((st ->> 'ppost')::int, 0) > 0 then
    d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + (st ->> 'pend')::int + coalesce((st ->> 'ppost')::int, 0)));
    d := d || jsonb_build_object('arena', jsonb_build_object('day', public.dc__day(), 'gained',
      case when d -> 'arena' ->> 'day' = public.dc__day() then public.dc__int(d -> 'arena', 'gained') else 0 end + (st ->> 'pend')::int));
  end if;
  if not exists (select 1 from jsonb_each(d -> 'coll') where key ~ '^\d+$' and key::int between 1 and 1025 and value::text::int > 0) then
    raise exception 'Ouvrez d’abord des boosters : la boutique de l’Arène propose les Pokémon de votre collection.'; end if;
  st := jsonb_build_object('round', 1, 'hp', (a ->> 'lives')::int, 'gold', (a ->> 'startGold')::int, 'wins', 0, 'credits', 0, 'n', 0,
    'board', '[null,null,null,null,null,null]'::jsonb, 'bench', (select jsonb_agg('null'::jsonb) from generate_series(1, public.dc__ar_bench())),
    'locked', false, 'over', false, 'shop', '[]'::jsonb);
  st := public.dc__ar_pshop(cfg, public.dc__ar_round(cfg, st, d -> 'coll'), d -> 'coll');
  insert into public.ar_runs (uid, data) values (u, st) on conflict (uid) do update set data = excluded.data, updated_at = now();
  d := public.dc__save(u, public.dc__bump(d, 'arRuns'));
  return public.dc__ar_view(d, st) || jsonb_build_object('profile', d);
end $$;

-- partie en cours, verrouillée pour une action
create or replace function public.dc__ar_get(u uuid) returns jsonb language plpgsql volatile as $$
declare st jsonb;
begin
  select data into st from public.ar_runs where uid = u for update;
  if st is null or coalesce((st ->> 'over')::boolean, false) then raise exception 'Aucune partie en cours : lancez-en une nouvelle.'; end if;
  -- 1.4.13 : banc de 9 places (8 avant) ; une partie commencée avant reçoit la place en plus
  if jsonb_array_length(st -> 'bench') < public.dc__ar_bench() then
    st := jsonb_set(st, '{bench}', (st -> 'bench') || (select jsonb_agg('null'::jsonb) from generate_series(1, public.dc__ar_bench() - jsonb_array_length(st -> 'bench'))));
  end if;
  return st;
end $$;
create or replace function public.dc__ar_put(u uuid, st jsonb) returns void language sql volatile as $$
  update public.ar_runs set data = st, updated_at = now() where uid = u $$;

create or replace function public.dc__ar_bench() returns int language sql immutable as $$ select 9 $$;   -- places du banc (8 avant la 1.4.13)
-- placement (glisser-déposer, ou toucher puis case) : p_board (6) et p_bench (places du banc ; plus court : complété de places vides,
-- pour une page pas encore rechargée), numéros d'unités ou null
create or replace function public.dc__ar_layout(st jsonb, p_board jsonb, p_bench jsonb) returns jsonb language plpgsql immutable as $$
declare units jsonb := '{}'; v jsonb; nb jsonb := '[]'; nc jsonb := '[]'; seen int := 0; k int;
begin
  if p_board is null or p_bench is null then return st; end if;
  if jsonb_array_length(p_board) <> 6 or jsonb_array_length(p_bench) > public.dc__ar_bench() then raise exception 'Placement invalide.'; end if;
  for v in select * from public.dc__ar_units(st) loop units := units || jsonb_build_object(v ->> 'u', v); end loop;
  for k in 0 .. 5 loop
    v := p_board -> k;
    if v = 'null' then nb := nb || 'null'::jsonb; else
      if not units ? (v #>> '{}') then raise exception 'Placement invalide.'; end if;
      nb := nb || (units -> (v #>> '{}')); units := units - (v #>> '{}'); seen := seen + 1; end if;
  end loop;
  if seen > public.dc__ar_max((st ->> 'round')::int) then raise exception 'Trop de Pokémon sur le terrain pour cette manche.'; end if;
  for k in 0 .. public.dc__ar_bench() - 1 loop
    v := coalesce(p_bench -> k, 'null');
    if v = 'null' then nc := nc || 'null'::jsonb; else
      if not units ? (v #>> '{}') then raise exception 'Placement invalide.'; end if;
      nc := nc || (units -> (v #>> '{}')); units := units - (v #>> '{}'); end if;
  end loop;
  if units <> '{}' then raise exception 'Placement invalide.'; end if;   -- chaque unité placée une fois, aucune oubliée
  return st || jsonb_build_object('board', nb, 'bench', nc);
end $$;

create or replace function public.dc_ar_layout(p_board jsonb, p_bench jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); st jsonb := public.dc__ar_get(u);
begin
  st := public.dc__ar_layout(st, p_board, p_bench);
  perform public.dc__ar_put(u, st);
  return jsonb_build_object('ok', true);
end $$;

-- achat de la case p_slot (0 à 4) ; placement actuel envoyé avec (p_board, p_bench), facultatif
create or replace function public.dc_ar_buy(p_slot int, p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); cfg jsonb := public.dc__cfg(); st jsonb := public.dc__ar_get(u);
  id int; c int; same int; free_ int; nu int;
begin
  st := public.dc__ar_layout(st, p_board, p_bench) - 'msg';
  if p_slot is null or p_slot < 0 or p_slot > 4 or st -> 'shop' -> p_slot = 'null' or st -> 'shop' -> p_slot is null then raise exception 'Cette case est vide.'; end if;
  id := (st -> 'shop' ->> p_slot)::int; c := public.dc__ar_cost(cfg, id);
  if (st ->> 'gold')::int < c then raise exception 'Pas assez d’or.'; end if;
  select count(*) into same from public.dc__ar_units(st) v where (v ->> 'i')::int = id and (v ->> 's')::int = 0;
  select min(k - 1) into free_ from jsonb_array_elements(st -> 'bench') with ordinality e(v, k) where v = 'null';
  if free_ is null and same < 2 then raise exception 'Votre banc est plein.'; end if;
  nu := (st ->> 'n')::int + 1;
  st := st || jsonb_build_object('n', nu, 'gold', (st ->> 'gold')::int - c, 'shop', jsonb_set(st -> 'shop', array[p_slot::text], 'null'));
  if free_ is not null then st := jsonb_set(st, array['bench', free_::text], jsonb_build_object('u', nu, 'i', id, 's', 0));
  else st := jsonb_set(st, '{bench}', (st -> 'bench') || jsonb_build_array(jsonb_build_object('u', nu, 'i', id, 's', 0))); end if;
  st := public.dc__ar_merge(cfg, st, id);
  st := jsonb_set(st, '{bench}', (select jsonb_agg(v order by k) from jsonb_array_elements(st -> 'bench') with ordinality e(v, k) where k <= public.dc__ar_bench()));
  perform public.dc__ar_put(u, st - 'msg');
  return public.dc__ar_view(d, st);
end $$;

create or replace function public.dc_ar_sell(p_u int, p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); cfg jsonb := public.dc__cfg(); st jsonb := public.dc__ar_get(u); v jsonb; z text; k int;
begin
  st := public.dc__ar_layout(st, p_board, p_bench) - 'msg';
  foreach z in array array['board', 'bench'] loop
    for k in 0 .. jsonb_array_length(st -> z) - 1 loop
      v := st -> z -> k;
      if v <> 'null' and (v ->> 'u')::int = p_u then
        st := jsonb_set(st, array[z, k::text], 'null');
        st := jsonb_set(st, '{gold}', to_jsonb((st ->> 'gold')::int + public.dc__ar_cost(cfg, (v ->> 'i')::int) * case (v ->> 's')::int when 2 then 9 when 1 then 3 else 1 end));
        perform public.dc__ar_put(u, st);
        return public.dc__ar_view(d, st);
      end if;
    end loop;
  end loop;
  raise exception 'Ce Pokémon n’est plus dans votre équipe.';
end $$;

create or replace function public.dc_ar_reroll(p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); cfg jsonb := public.dc__cfg(); st jsonb := public.dc__ar_get(u);
begin
  st := public.dc__ar_layout(st, p_board, p_bench) - 'msg';
  if (st ->> 'gold')::int < (cfg -> 'arena' ->> 'reroll')::int then raise exception 'Pas assez d’or.'; end if;
  st := jsonb_set(st, '{gold}', to_jsonb((st ->> 'gold')::int - (cfg -> 'arena' ->> 'reroll')::int));
  st := jsonb_set(st, '{shop}', public.dc__ar_shop(cfg, st, d -> 'coll'));
  perform public.dc__ar_put(u, st);
  return public.dc__ar_view(d, st);
end $$;

drop function if exists public.dc_ar_lock(boolean);   -- 1.3.2 : la page envoie aussi le placement, comme pour les autres actions
create or replace function public.dc_ar_lock(p_on boolean, p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, false); st jsonb := public.dc__ar_get(u);
begin
  st := jsonb_set(public.dc__ar_layout(st, p_board, p_bench) - 'msg', '{locked}', to_jsonb(coalesce(p_on, false)));
  perform public.dc__ar_put(u, st);
  return public.dc__ar_view(d, st);
end $$;

-- ---------- combat ----------
-- simulation : chacun frappe dans l'ordre de Vitesse ; cible : la ligne de devant adverse, la colonne la plus proche,
-- puis le moins de PV. Dégâts = Atq² / (Atq + Déf) × 0,45 × type × (0,9 à 1,1). Synergies : 2 Pokémon différents
-- d'un type = +15 % PV et Attaque pour ce type, 4 = +30 %. Étoile : ×1,6.
create or replace function public.dc__ar_sim(cfg jsonb, board jsonb, enemy jsonb) returns jsonb language plpgsql volatile as $$
declare sc text := cfg ->> 'arStat'; pt text := cfg ->> 'ptype'; ch text := cfg ->> 'arChart';
  sd int[] := '{}'; rw int[] := '{}'; cl int[] := '{}'; hp int[] := '{}'; mx int[] := '{}'; atk numeric[] := '{}'; df numeric[] := '{}'; sp int[] := '{}';
  ids int[] := '{}'; us int[] := '{}'; ty jsonb := '[]'; syn int[]; side int; k int; v jsonb; st int[]; b numeric; t int; s numeric; pw numeric;
  log jsonb := '[]'; tick int := 0; o int; i int; tg int; m numeric; dmg int; alive0 int; alive1 int; n int; best int; win boolean;
begin
  for side in 0 .. 1 loop
    syn := array_fill(0, array[18]);
    for v in select distinct on ((x ->> 'i')::int) x from jsonb_array_elements(case side when 0 then board else enemy -> 'board' end) x where x <> 'null' loop
      foreach t in array public.dc__ar_types(pt, (v ->> 'i')::int) loop syn[t] := syn[t] + 1; end loop;
    end loop;
    pw := case side when 0 then 1 else (enemy ->> 'power')::numeric end;
    for k in 0 .. 5 loop
      v := case side when 0 then board -> k else enemy -> 'board' -> k end;
      continue when v is null or v = 'null';
      st := public.dc__ar_stat(sc, (v ->> 'i')::int); b := 0;
      foreach t in array public.dc__ar_types(pt, (v ->> 'i')::int) loop b := greatest(b, case when syn[t] >= 6 then .45 when syn[t] >= 4 then .3 when syn[t] >= 2 then .15 else 0 end); end loop;
      s := public.dc__ar_stark(cfg, (v ->> 'i')::int, (v ->> 's')::int);
      sd := sd || side; rw := rw || (k / 3); cl := cl || (k % 3); ids := ids || (v ->> 'i')::int; us := us || (v ->> 'u')::int;
      mx := mx || round((2 * st[1] + 60) * s * (1 + b) * pw)::int; atk := atk || (greatest(st[2], st[4]) * s * (1 + b) * pw); df := df || ((st[3] + st[5]) / 2.0); sp := sp || st[6];
      ty := ty || jsonb_build_array(to_jsonb(public.dc__ar_types(pt, (v ->> 'i')::int)));
    end loop;
  end loop;
  hp := mx; n := coalesce(array_length(sd, 1), 0);
  loop
    select count(*) filter (where sd[x] = 0 and hp[x] > 0), count(*) filter (where sd[x] = 1 and hp[x] > 0) into alive0, alive1 from generate_series(1, n) x;
    exit when alive0 = 0 or alive1 = 0 or tick >= 40;
    tick := tick + 1;
    for o in select x from generate_series(1, n) x where hp[x] > 0 order by sp[x] desc, random() loop
      continue when hp[o] <= 0;
      select x into tg from generate_series(1, n) x where sd[x] <> sd[o] and hp[x] > 0
        order by (rw[x] = 0) desc, abs(cl[x] - cl[o]), hp[x] limit 1;
      exit when tg is null;
      m := public.dc__ar_mult(ch, array(select jsonb_array_elements_text(ty -> (o - 1))::int), array(select jsonb_array_elements_text(ty -> (tg - 1))::int));
      dmg := case when m = 0 then 0 else greatest(3, round(atk[o] * atk[o] / (atk[o] + df[tg]) * .45 * m * (.9 + random() * .2))::int) end;
      hp[tg] := greatest(0, hp[tg] - dmg);
      log := log || jsonb_build_array(jsonb_build_array(us[o], us[tg], dmg, m, hp[tg], mx[tg]));
    end loop;
  end loop;
  select count(*) filter (where sd[x] = 0 and hp[x] > 0), count(*) filter (where sd[x] = 1 and hp[x] > 0) into alive0, alive1 from generate_series(1, n) x;
  win := alive0 > 0 and alive1 = 0;
  if alive0 > 0 and alive1 > 0 then   -- temps écoulé : l'équipe qui garde le plus de PV (en proportion) gagne
    select sum(hp[x]::numeric / mx[x]) filter (where sd[x] = 0) > sum(hp[x]::numeric / mx[x]) filter (where sd[x] = 1) into win from generate_series(1, n) x;
  end if;
  return jsonb_build_object('log', log, 'win', coalesce(win, false));
end $$;

-- combat de la manche : placement envoyé par la page, places libres remplies d'office par les plus forts du banc,
-- simulation, crédits (dans la limite du jour), puis manche suivante ou fin de partie
create or replace function public.dc_ar_fight(p_board jsonb default null, p_bench jsonb default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg(); a jsonb := cfg -> 'arena';
  st jsonb := public.dc__ar_get(u); rd int; res jsonb; auto_ jsonb := '[]'; v jsonb; k int; before jsonb; oe jsonb; day text := public.dc__day();
  gained bigint; pend bigint := coalesce((st ->> 'pend')::bigint, 0); added bigint := 0; bonus bigint := 0; post bigint := 0; cap bigint := (a ->> 'cap')::bigint; win boolean; nr int;
begin
  st := public.dc__ar_layout(public.dc__ar_pshop(cfg, st, d -> 'coll'), p_board, p_bench) - 'msg'; rd := (st ->> 'round')::int;
  -- places libres : les Pokémon les plus forts du banc (total des statistiques, étoile comprise)
  while (select count(*) from jsonb_array_elements(st -> 'board') x where x <> 'null') < public.dc__ar_max(rd) loop
    select x, j - 1 into v, k from jsonb_array_elements(st -> 'bench') with ordinality e(x, j) where x <> 'null'
      order by (select sum(s) from unnest(public.dc__ar_stat(cfg ->> 'arStat', (x ->> 'i')::int)) s) * public.dc__ar_stark(cfg, (x ->> 'i')::int, (x ->> 's')::int) desc limit 1;
    exit when v is null;
    st := jsonb_set(st, array['bench', k::text], 'null');
    st := jsonb_set(st, array['board', (select min(j - 1) from jsonb_array_elements(st -> 'board') with ordinality e(x, j) where x = 'null')::text], v);
    auto_ := auto_ || (v -> 'i'); v := null;
  end loop;
  if (select count(*) from jsonb_array_elements(st -> 'board') x where x <> 'null') = 0 then raise exception 'Placez au moins un Pokémon sur le terrain.'; end if;
  before := jsonb_build_object('board', st -> 'board', 'bench', st -> 'bench', 'enemy', st -> 'enemy');
  res := public.dc__ar_sim(cfg, st -> 'board', st -> 'enemy');
  -- 1.5.5 (demande de Theo) : les crédits de la partie restent en cagnotte (pend : comptés dans le plafond du jour, ppost : après
  -- le plafond) et ne sont versés qu'à la fin de la partie, réussie ou non ; gained compte la cagnotte pour le plafond
  gained := case when d -> 'arena' ->> 'day' = day then public.dc__int(d -> 'arena', 'gained') else 0 end + pend;
  if (res ->> 'win')::boolean then
    added := least((a ->> 'winBase')::int + (a ->> 'winStep')::int * rd, greatest(0, cap - gained));
    -- 1.5.4 (demande de Theo) : plafond du jour déjà atteint, une manche gagnée du premier coup rapporte encore afterRound (20)
    -- crédits, hors compteur du jour ; une manche perdue ne rapporte rien, ni plus tard quand elle est rejouée et gagnée
    if gained >= cap and not coalesce(st -> 'hist', '[]') @> jsonb_build_array(jsonb_build_array(rd, 0)) then
      post := coalesce((a ->> 'afterRound')::int, 0);
    end if;
    st := st || jsonb_build_object('wins', (st ->> 'wins')::int + 1, 'gold', (st ->> 'gold')::int + 1);
    d := public.dc__bump(d, 'arWins');
  else
    st := st || jsonb_build_object('hp', greatest(0, (st ->> 'hp')::int - 1), 'gold', (st ->> 'gold')::int + (a ->> 'lossGold')::int);
  end if;
  win := (res ->> 'win')::boolean;
  -- issue de chaque combat, [manche, 1 gagnée ou 0 perdue], pour la progression affichée (1.3.14 ; 1.4.2 : avec la manche,
  -- car une manche perdue se rejoue)
  st := jsonb_set(st, '{hist}', coalesce(st -> 'hist', '[]') || jsonb_build_array(jsonb_build_array(rd, case when win then 1 else 0 end)));
  -- fin de partie : plus de vie, ou dernière manche gagnée (seul moyen de réussir l'Arène, règle de Theo 1.3.19)
  if (st ->> 'hp')::int <= 0 or (win and rd >= (a ->> 'rounds')::int) then
    st := jsonb_set(st, '{over}', 'true');
    if win then
      st := jsonb_set(st, '{done}', 'true');
      -- plafond du jour atteint (ou atteint par cette fin de partie) : encore afterCap crédits, hors compteur du jour,
      -- afterCapPerfect sans avoir perdu de vie (1.3.14 ; 100 et 150 de la 1.4.2 à la 1.5.3, 20 et 50 depuis, demande de Theo)
      bonus := least((a ->> 'finish')::int, greatest(0, cap - gained - added));
      if gained + added + bonus >= cap then
        post := post + case when (st ->> 'hp')::int >= (a ->> 'lives')::int then coalesce((a ->> 'afterCapPerfect')::int, (a ->> 'afterCap')::int, 0)
                     else coalesce((a ->> 'afterCap')::int, 0) end;
      end if;
      d := public.dc__bump(d, 'arDone');
      -- titre Invaincu (1.3.6) : l'Arène réussie sans perdre une vie
      if (st ->> 'hp')::int >= (a ->> 'lives')::int then d := jsonb_set(d, '{stats,arPerf}', '1'); end if;
    end if;
  else
    -- 1.4.2 (demande de Theo) : une manche perdue se rejoue (nouvel adversaire), avec lossGold en plus de l'or de la manche
    nr := case when win then rd + 1 else rd end;
    st := st || jsonb_build_object('round', nr);
    -- or de la manche : base + incStep × manche (1.4.8 : 1, la moitié avant), moins incLate à partir de la manche 5, plus les intérêts
    -- (1.4.0 : 10 or gardés = +1, 20 = +3, 30 et plus = +5, table interest de la config)
    st := jsonb_set(st, '{gold}', to_jsonb((st ->> 'gold')::int + (a ->> 'incBase')::int + floor(nr * coalesce((a ->> 'incStep')::numeric, .5))::int
      - case when nr >= 5 then coalesce((a ->> 'incLate')::int, 0) else 0 end
      + coalesce((a -> 'interest' ->> least(3, (st ->> 'gold')::int / 10))::int, least(3, (st ->> 'gold')::int / 10))));
    oe := st -> 'enemy';
    st := public.dc__ar_round(cfg, st, d -> 'coll');
    -- 1.4.8 (demande de Theo) : une manche perdue se rejoue contre la même équipe (nouvel adversaire de la 1.4.2 à la 1.4.7)
    if not win then st := jsonb_set(st, '{enemy}', oe); end if;
  end if;
  st := jsonb_set(st, '{credits}', to_jsonb((st ->> 'credits')::int + added + bonus + post));
  if (st ->> 'over')::boolean then
    d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') + pend + coalesce((st ->> 'ppost')::int, 0) + added + bonus + post));
    d := d || jsonb_build_object('arena', jsonb_build_object('day', day, 'gained', gained + added + bonus));
    st := st - 'pend' - 'ppost';
  else
    st := st || jsonb_build_object('pend', pend + added + bonus, 'ppost', coalesce((st ->> 'ppost')::int, 0) + post);
  end if;
  perform public.dc__ar_put(u, st);
  d := public.dc__save(u, d);
  return public.dc__ar_view(d, st) || jsonb_build_object('profile', d, 'before', before, 'log', res -> 'log', 'win', res -> 'win',
    'added', added, 'bonus', bonus, 'post', post, 'auto', auto_, 'round', rd);
end $$;

-- ============================================================
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dc\_\_ar\_%' or p.proname like 'dc\_ar\_%') loop
    execute format('revoke all on function %s from public, anon%s', f.sig, case when f.proname like 'dc\_\_%' then ', authenticated' else '' end);
    if f.proname not like 'dc\_\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 5 OK' as verif, (select count(*) from pg_proc where proname like 'dc_ar_%') as fonctions_arene;
