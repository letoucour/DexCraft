-- ============================================================
--  DexCraft — base de données (Supabase)
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Ce script peut être relancé autant de fois que nécessaire.
--
--  Installation complète, dans cet ordre :
--    1. dexcraft-supabase.sql  (ce fichier : tables et droits)
--    2. dexcraft-config.sql    (données du jeu, généré par outils\generer-config.ps1)
--    3. dexcraft-serveur.sql   (fonctions du jeu : le serveur est l'arbitre)
--  Depuis la 0.4.0, les joueurs ne peuvent QUE LIRE la table docs : toute
--  modification passe par les fonctions dc_* de dexcraft-serveur.sql.
-- ============================================================

-- 1) Table unique : profils des joueurs et annonces du marché
create table if not exists public.docs (
  path         text primary key,          -- "players/<uuid>" ou "market/<id>"
  coll         text not null,             -- "players" ou "market"
  data         jsonb not null default '{}'::jsonb,
  lease_holder text,
  lease_until  timestamptz,
  updated_at   timestamptz not null default now()
);

create index if not exists docs_coll_idx on public.docs (coll);

-- 2) Table des administrateurs (mode développeur et gestion des joueurs)
create table if not exists public.admins (
  uid uuid primary key
);

-- 3) Pas de limite de joueurs : on retire l'ancienne limite si elle existe encore
drop trigger if exists docs_player_limit on public.docs;
drop function if exists public.check_player_limit();

-- 4) Ancien verrou du jeu, remplacé par les verrous des fonctions du serveur (0.4.0) : supprimé
drop function if exists public.acquire_lease(text, text, timestamptz);

-- 5) Droits d'accès : les joueurs connectés LISENT seulement (anti-triche, 0.4.0)
grant usage on schema public to anon, authenticated;
grant select on public.docs   to authenticated;
grant select on public.admins to authenticated;
revoke insert, update, delete on public.docs from anon, authenticated;

-- aucune écriture automatique sur les tables créées plus tard
alter default privileges in schema public revoke insert, update, delete on tables from authenticated;

-- 6) Sécurité : lecture pour les joueurs connectés, écriture uniquement par les fonctions du jeu
alter table public.docs   enable row level security;
alter table public.admins enable row level security;

drop policy if exists docs_read   on public.docs;
drop policy if exists docs_write  on public.docs;
drop policy if exists admins_read on public.admins;

create policy docs_read on public.docs
  for select to authenticated
  using (true);

create policy admins_read on public.admins
  for select to authenticated
  using (true);

-- 7) Mises à jour en temps réel (classement, enchères, échanges)
--    Ignoré sans erreur si la table y est déjà, ou si la publication couvre tout.
do $$
begin
  begin
    alter publication supabase_realtime add table public.docs;
  exception when others then
    raise notice 'Realtime deja configure (%).', sqlerrm;
  end;
end $$;

-- 8) Vérification : ces lignes doivent répondre sans erreur
select 'table docs OK'     as verif, count(*) as lignes from public.docs;
select 'table admins OK'   as verif, count(*) as lignes from public.admins;
select 'droits docs OK'    as verif,
       has_table_privilege('authenticated', 'public.docs', 'SELECT') as lecture,
       has_table_privilege('authenticated', 'public.docs', 'INSERT') as ecriture;

-- ============================================================
--  APRÈS VOTRE PREMIÈRE CONNEXION AU JEU
--  Déclarez-vous administrateur pour pouvoir créditer les autres joueurs.
--  Remplacez l'adresse par la vôtre, sélectionnez ces trois lignes, puis Run.
-- ============================================================
-- insert into public.admins (uid)
-- select id from auth.users where email = 'theo.lostria@gmail.com'
-- on conflict do nothing;

-- Vérifier que c'est bien pris en compte :
-- select u.email, a.uid from public.admins a join auth.users u on u.id = a.uid;

-- ============================================================
--  ENTRETIEN
-- ============================================================
-- Voir les joueurs inscrits :
--   select path, data->>'pseudo' as pseudo, data->>'unique' as pokemon, data->>'credits' as credits
--   from public.docs where coll = 'players';
--
-- Supprimer un joueur :
--   delete from public.docs where path = 'players/<uuid-du-joueur>';
--
-- Tout remettre à zéro :
--   delete from public.docs;
