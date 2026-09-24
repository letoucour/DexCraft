-- ============================================================
--  DexCraft — serveur, PARTIE 3 / 3 : codes cadeaux et suppression des comptes
--  À coller dans Supabase > SQL Editor > Run, APRÈS dexcraft-serveur.sql et dexcraft-serveur-2.sql.
--  Relançable sans risque.
-- ============================================================

-- ---------- codes cadeaux ----------
create table if not exists public.promo_codes (
  code     text primary key,               -- en majuscules, ex. MONEY
  credits  bigint not null default 0,
  packs    int not null default 0,         -- boosters ajoutés à la réserve achetée (bonus)
  active   boolean not null default true,
  max_uses int,                            -- nombre total d'utilisations (tous joueurs), null = illimité
  uses     int not null default 0
);
create table if not exists public.promo_redemptions (   -- un code ne sert qu'une fois par joueur
  code text not null references public.promo_codes(code) on delete cascade,
  uid  uuid not null,
  at   timestamptz not null default now(),
  primary key (code, uid)
);
alter table public.promo_codes enable row level security;
alter table public.promo_redemptions enable row level security;
revoke all on public.promo_codes, public.promo_redemptions from anon, authenticated;

-- code MONEY : 1 000 crédits, une fois par joueur
insert into public.promo_codes (code, credits) values ('MONEY', 1000) on conflict (code) do nothing;

create or replace function public.dc_redeem_code(p_code text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := public.dc__uid(); c public.promo_codes; d jsonb; k text := upper(btrim(coalesce(p_code, '')));
begin
  if k = '' then raise exception 'Entrez un code.'; end if;
  select * into c from public.promo_codes where code = k for update;
  if not found or not c.active then raise exception 'Ce code n’existe pas ou n’est plus valable.'; end if;
  if c.max_uses is not null and c.uses >= c.max_uses then raise exception 'Ce code a déjà été utilisé.'; end if;
  if exists (select 1 from public.promo_redemptions where code = k and uid = u) then raise exception 'Vous avez déjà utilisé ce code.'; end if;
  d := public.dc__lock(u, true);
  insert into public.promo_redemptions (code, uid) values (k, u);
  update public.promo_codes set uses = uses + 1 where code = k;
  d := d || jsonb_build_object('credits', public.dc__int(d, 'credits') + c.credits, 'bonus', public.dc__int(d, 'bonus') + c.packs);
  return jsonb_build_object('profile', public.dc__save(u, d), 'code', k, 'credits', c.credits, 'packs', c.packs);
end $$;

-- ---------- suppression d'un joueur ----------
-- Efface son profil, sa partie de VoltoBataille et ses annonces, en rendant aux autres ce qui leur revient.
create or replace function public.dc__purge_player(u uuid) returns void language plpgsql volatile as $$
declare m record; o jsonb; k text;
begin
  for m in select path, data from public.docs where coll = 'market' for update loop
    if m.data ->> 'kind' = 'a' and m.data ->> 'seller' = u::text then           -- sa vente : l'enchérisseur est remboursé
      if m.data ->> 'bidder' is not null and exists (select 1 from public.docs where path = 'players/' || (m.data ->> 'bidder')) then
        o := public.dc__lock((m.data ->> 'bidder')::uuid);
        perform public.dc__save((m.data ->> 'bidder')::uuid, jsonb_set(o, '{credits}', to_jsonb(public.dc__int(o, 'credits') + public.dc__int(m.data, 'bid'))), false);
      end if;
      delete from public.docs where path = m.path;
    elsif m.data ->> 'kind' = 'a' and m.data ->> 'bidder' = u::text then        -- sa mise : l'enchère repart sans offre
      update public.docs set data = m.data || jsonb_build_object('bid', 0, 'bidder', null), updated_at = now() where path = m.path;
    elsif m.data ->> 'kind' = 't' and m.data ->> 'owner' = u::text then         -- son échange : les propositions sont rendues
      perform public.dc__return_offers(m.data, null);
      delete from public.docs where path = m.path;
    elsif m.data ->> 'kind' = 't' then                                           -- ses propositions chez les autres : retirées
      for k in select key from jsonb_each(m.data -> 'offers') where value ->> 'by' = u::text loop
        update public.docs set data = jsonb_set(data, '{offers}', (data -> 'offers') - k), updated_at = now() where path = m.path;
      end loop;
    end if;
  end loop;
  delete from public.vb_rounds where uid = u;
  delete from public.promo_redemptions where uid = u;
  delete from public.admins where uid = u;
  delete from public.docs where path = 'players/' || u;
end $$;

-- automatique : supprimer un compte (Authentication > Users > Delete user) supprime aussi son profil de jeu
create or replace function public.dc__on_user_deleted() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.dc__purge_player(old.id);
  return old;
end $$;
drop trigger if exists dc_user_deleted on auth.users;
create trigger dc_user_deleted after delete on auth.users for each row execute function public.dc__on_user_deleted();

-- nettoyage des profils dont le compte a déjà été supprimé
do $$
declare p record; n int := 0;
begin
  for p in select path from public.docs where coll = 'players'
           and not exists (select 1 from auth.users u where 'players/' || u.id = path) loop
    perform public.dc__purge_player(substr(p.path, 9)::uuid); n := n + 1;
  end loop;
  raise notice 'Profils orphelins supprimés : %', n;
end $$;

-- ---------- droits d'exécution ----------
revoke all on function public.dc_redeem_code(text) from public, anon;
grant execute on function public.dc_redeem_code(text) to authenticated;
revoke all on function public.dc__purge_player(uuid) from public, anon, authenticated;
revoke all on function public.dc__on_user_deleted() from public, anon, authenticated;

select 'serveur DexCraft partie 3 OK' as verif,
  (select count(*) from public.docs where coll = 'players') as joueurs,
  (select count(*) from public.promo_codes) as codes;
