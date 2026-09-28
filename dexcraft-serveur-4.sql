-- ============================================================
--  DexCraft — fonctions du serveur, PARTIE 4 (1.2.3) : boosters spéciaux.
--  À lancer après dexcraft-serveur.sql, dexcraft-serveur-2.sql et dexcraft-serveur-3.sql (et la configuration).
-- ============================================================

-- Tirage de p_k boosters spéciaux dans le profil d, sans l'enregistrer. Renvoie {d, drawn}.
--   'gen'  : 5 cartes de la génération p_val (1 à 9) ;
--   'type' : 5 cartes du type p_val (1 à 18) ;
--   'prem' : 5 cartes Rare ou mieux (chances premK : mythiques et transcendantes à leur taux habituel).
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

-- Achat en crédits et ouverture immédiate (gratuit pour l'administrateur en mode développeur, comme dc_buy_packs).
create or replace function public.dc_open_special(p_kind text, p_val int, p_k int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); d jsonb := public.dc__lock(u, true); cfg jsonb := public.dc__cfg();
  price bigint := (cfg -> 'spb' -> p_kind ->> 'price')::bigint; free_ boolean; o jsonb; now_ms bigint := public.dc__now();
begin
  if price is null then raise exception 'Booster inconnu.'; end if;
  if not (cfg -> 'openOpts' @> to_jsonb(p_k)) then raise exception 'Nombre de boosters invalide.'; end if;
  free_ := public.dc__is_admin(u) and coalesce((d ->> 'dev')::boolean, false);
  if not free_ then
    if public.dc__int(d, 'credits') < price * p_k then raise exception 'Vous n’avez pas assez de crédits.'; end if;
    d := jsonb_set(d, '{credits}', to_jsonb(public.dc__int(d, 'credits') - price * p_k));
  end if;
  o := public.dc__open_special(d, cfg, p_kind, p_val, p_k); d := o -> 'd';
  -- comme dc_open : dernier tirage (réponse perdue) et 50 dernières cartes tirées
  d := d || jsonb_build_object('lastOpen', jsonb_build_object('t', now_ms, 'drawn', o -> 'drawn'),
    'recent', (select jsonb_agg(v order by n) from jsonb_array_elements((o -> 'drawn') || coalesce(d -> 'recent', '[]'))
      with ordinality as x(v, n) where n <= 50));
  return jsonb_build_object('profile', public.dc__save(u, d), 'drawn', o -> 'drawn', 'free', free_);
end $$;

-- Outil administrateur : boosters de toutes sortes dans la boîte cadeau d'un joueur.
-- 'pk' : boosters normaux (vont dans sa réserve à l'ouverture) ; 'gen', 'type', 'prem' : ouverts avec le cadeau (dc_gift_open).
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
--  Droits d'exécution des fonctions de cette partie
-- ============================================================
revoke all on function public.dc__open_special(jsonb,jsonb,text,integer,integer) from public, anon, authenticated;
revoke all on function public.dc_open_special(text,integer,integer) from public, anon;
grant execute on function public.dc_open_special(text,integer,integer) to authenticated;
revoke all on function public.dc_admin_give_booster(uuid,text,integer,integer) from public, anon;
grant execute on function public.dc_admin_give_booster(uuid,text,integer,integer) to authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'dc%' and (p.proconfig is null or not exists
             (select 1 from unnest(p.proconfig) c where c like 'search_path=%')) loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

select 'serveur DexCraft partie 4 OK' as verif, (select count(*) from pg_proc where proname in ('dc_open_special', 'dc_admin_give_booster')) as fonctions;
