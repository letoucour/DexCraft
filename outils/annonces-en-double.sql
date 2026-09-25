-- ============================================================
--  DexCraft — retirer les annonces d'échange en double d'un joueur
--  (bug de la 0.6.3 : un second clic sur « Proposer » publiait toute la liste une deuxième fois).
--
--  Pour chaque carte mise plusieurs fois à l'échange par ce joueur, garde la plus ancienne annonce
--  et retire les autres, en rendant la carte à sa collection. Une annonce qui a déjà reçu
--  une proposition n'est jamais touchée.
--
--  1. Remplacez l'adresse e-mail ci-dessous (deux fois).
--  2. Lancez d'abord la partie APERÇU seule (sélectionnez-la, puis Run) : elle liste ce qui sera retiré.
--  3. Puis lancez la partie NETTOYAGE.
-- ============================================================

-- ---------- APERÇU ----------
with j as (select id from auth.users where email = 'theo.lostria@gmail.com'),
a as (
  select d.path, (d.data ->> 'card')::int as card, (d.data ->> 'created')::bigint as created,
         row_number() over (partition by d.data ->> 'card' order by (d.data ->> 'created')::bigint, d.path) as rang
  from public.docs d, j
  where d.coll = 'market' and d.data ->> 'kind' = 't' and d.data ->> 'status' = 'open' and d.data ->> 'owner' = j.id::text
    and not exists (select 1 from jsonb_each(d.data -> 'offers') o where o.value ->> 'status' = 'pending')
)
select count(*) filter (where rang > 1) as annonces_a_retirer, count(distinct card) filter (where rang > 1) as cartes_concernees from a;

-- ---------- NETTOYAGE ----------
do $$
declare u uuid; p record; d jsonb; n int := 0;
begin
  select id into u from auth.users where email = 'theo.lostria@gmail.com';
  if u is null then raise exception 'Adresse e-mail inconnue.'; end if;
  d := public.dc__lock(u);
  for p in
    select path, card from (
      select d2.path, (d2.data ->> 'card')::int as card,
             row_number() over (partition by d2.data ->> 'card' order by (d2.data ->> 'created')::bigint, d2.path) as rang
      from public.docs d2
      where d2.coll = 'market' and d2.data ->> 'kind' = 't' and d2.data ->> 'status' = 'open' and d2.data ->> 'owner' = u::text
        and not exists (select 1 from jsonb_each(d2.data -> 'offers') o where o.value ->> 'status' = 'pending')
    ) s where rang > 1
  loop
    delete from public.docs where path = p.path;
    d := public.dc__add(d, p.card, 1);
    n := n + 1;
  end loop;
  perform public.dc__save(u, d, false);
  raise notice 'Annonces en double retirées : %, cartes rendues à la collection.', n;
end $$;
