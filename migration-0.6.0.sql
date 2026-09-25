-- ============================================================
--  DexCraft 0.6.0 — UNE SEULE FOIS, sur le vrai Supabase, APRÈS dexcraft-config.sql et les trois parties
--  du serveur (dexcraft-serveur.sql, -2, -3), juste avant le push. Relançable sans risque.
--
--  1. Pseudos : ceux qui étaient encore le début de l'adresse e-mail (jamais choisis) sont remplacés par
--     un pseudo provisoire « Dresseur 1234 » ; ces joueurs choisiront le leur à la prochaine connexion.
--  2. Tous les profils sont recalculés (titres affichés « shown », anciens champs listings et escrow retirés).
--  3. Colonnes de l'ancien verrou (lease_holder, lease_until) supprimées.
-- ============================================================
do $$
declare p record; em text; n_mail int := 0; n int := 0; v text;
begin
  for p in select path, data from public.docs where coll = 'players' for update loop
    v := p.data ->> 'pseudoSet';
    if v is null then
      select split_part(coalesce(email, ''), '@', 1) into em from auth.users where 'players/' || id = p.path;
      if public.dc__int(p.data, 'pseudoTs') > 0 then
        v := 'true';
      elsif coalesce(p.data ->> 'pseudo', '') = '' or p.data ->> 'pseudo' = left(coalesce(em, ''), 20) then
        update public.docs set data = data || jsonb_build_object('pseudo', 'Dresseur ' || lpad(public.dc__rnd(10000)::text, 4, '0'), 'pseudoSet', false)
          where path = p.path;
        n_mail := n_mail + 1; v := null;
      else
        v := 'true';        -- pseudo choisi avant l'arrivée du délai de 7 jours
      end if;
      if v is not null then update public.docs set data = data || '{"pseudoSet": true}' where path = p.path; end if;
    end if;
    update public.docs set data = public.dc__stamp(data, false) where path = p.path;
    n := n + 1;
  end loop;
  raise notice 'Profils recalculés : %, pseudos tirés de l’e-mail remplacés : %', n, n_mail;
end $$;

alter table public.docs drop column if exists lease_holder;
alter table public.docs drop column if exists lease_until;

select 'migration 0.6.0 OK' as verif,
  (select count(*) from public.docs where coll = 'players') as joueurs,
  (select count(*) from public.docs where coll = 'players' and not (data ? 'shown')) as sans_titres_calcules,
  (select count(*) from public.docs where coll = 'players' and data ->> 'pseudoSet' = 'false') as pseudo_a_choisir;
