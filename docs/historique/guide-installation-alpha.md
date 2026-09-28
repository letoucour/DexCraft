# DexCraft — mettre l'alpha en ligne gratuitement

Objectif : une adresse web que vos testeurs ouvrent sans compte Claude, avec sauvegarde en ligne, classement, enchères et échanges partagés. Coût : 0 €.

Deux services gratuits suffisent : **Supabase** pour les comptes et la base de données, **Netlify** pour héberger la page.

Trois fichiers : `dexcraft-web.html` (le jeu, déjà configuré avec vos clés), `dexcraft-supabase.sql` (la base), et ce guide.

---

## 1. Créer la base Supabase

1. Sur **supabase.com**, créez un compte puis un projet nommé `dexcraft`, plan **Free**, région proche.
2. Menu **SQL Editor** > **New query**.
3. Collez tout le contenu de `dexcraft-supabase.sql` et cliquez sur **Run**.
4. **Vérifiez le résultat.** Le script se termine par quatre vérifications. Vous devez voir : `table docs OK`, `table admins OK`, `fonction lease OK`, et `droits docs OK` avec `lecture = true` et `ecriture = true`. Si un message rouge apparaît à la place, rien n'a été créé : corrigez l'erreur et relancez. Le script peut être relancé autant de fois que nécessaire, il ne casse rien.
5. Second contrôle : menu **Table Editor**, vous devez voir les tables `docs` et `admins`.

## 2. Simplifier la création de comptes

1. Menu **Authentication** > **Sign In / Providers** > **Email**.
2. Désactivez **Confirm email**, puis enregistrez. Vos testeurs jouent immédiatement, sans attendre un e-mail.

## 3. Vos clés (déjà remplies)

Le fichier `dexcraft-web.html` contient déjà votre adresse de projet et votre clé publique `anon`. Rien à faire. Pour information, ces valeurs se retrouvent dans **Project Settings** > **API Keys**. La clé `anon` est prévue pour être publique : elle ne donne aucun pouvoir en dehors des règles posées par le fichier SQL.

## 4. Vous déclarer administrateur

C'est déjà fait : le fichier contient votre adresse.

```js
const ADMIN_EMAILS=["theo.lostria@gmail.com"];
```

Le bloc **Mode développeur** s'affiche donc dans votre profil dès que vous vous connectez avec cette adresse. Pour ajouter un second administrateur plus tard, complétez cette liste, séparée par des virgules.

Pour pouvoir en plus **créditer d'autres joueurs** ou leur donner le badge Alpha testeur, il faut aussi vous ajouter à la table `admins`, après avoir créé votre compte dans le jeu (étape 6).

## 5. Mettre la page en ligne

1. Allez sur **app.netlify.com/drop**.
2. Glissez-déposez `dexcraft-web.html`.
3. Netlify demande **« Rename to index.html? »** : cliquez sur **Rename and deploy**. Le jeu devient la page d'accueil du site. Avec « Deploy without renaming », l'accueil afficherait « Page Not Found ».
4. Créez un compte Netlify gratuit pour conserver l'adresse.
5. Dans **Site configuration** > **Change site name**, choisissez un nom court, par exemple `dexcraft-alpha`.
6. Ouvrez l'adresse : l'écran de connexion DexCraft doit apparaître.

Pour mettre à jour le jeu plus tard, glissez le nouveau fichier au même endroit et acceptez à nouveau le renommage.

**Rendre le site accessible à vos testeurs :** dans **Site configuration** > **Visitor access** > **Project visibility**, choisissez **Customize this project's visibility**, puis **Public**, puis **Production and previews**, et enregistrez. Sans cela, vos testeurs voient « This site is private » et Netlify leur demande un compte. « Public » ne référence pas le site : il reste accessible uniquement à ceux qui ont l'adresse, et le seul compte à créer est celui du jeu.

**Rien à faire dans « Environment variables » de Netlify.** Le jeu est un simple fichier HTML : ses clés sont écrites dedans, pas dans Netlify.

## 6. Créer votre compte et activer les droits complets

1. Sur le site, créez votre compte avec votre e-mail et un mot de passe.
2. Le jeu doit afficher **« Connecté »** dans l'onglet Profil. Si vous lisez « Partie locale », voyez la section Dépannage plus bas.
3. Dans Supabase > **SQL Editor**, exécutez ces trois lignes :

```sql
insert into public.admins (uid)
select id from auth.users where email = 'theo.lostria@gmail.com'
on conflict do nothing;
```

4. Vérifiez avec :

```sql
select u.email, a.uid from public.admins a join auth.users u on u.id = a.uid;
```

Votre adresse doit apparaître. Rechargez le jeu : vous pouvez désormais créditer les autres joueurs depuis vos outils développeur.

## 7. Inviter vos testeurs

Envoyez l'adresse Netlify. Chacun crée son compte et joue. Il n'y a pas de limite de joueurs.

---

## Mettre à jour le jeu sans rien casser

Le jeu est un seul fichier HTML : le mettre à jour ne touche jamais aux comptes ni aux collections, qui vivent dans Supabase.

**Mise à jour normale, en deux minutes :**
1. Récupérez le nouveau `dexcraft-web.html`. Vos clés et votre adresse administrateur y sont déjà.
2. Allez sur votre site dans Netlify, onglet **Deploys**, et glissez le fichier dans la zone « Drag and drop your site output folder here » en bas de page. Acceptez le renommage en `index.html`.
3. Demandez à vos testeurs de recharger la page en forçant le rafraîchissement : **Ctrl + F5** sur Windows, **Cmd + Maj + R** sur Mac. Sinon, le navigateur peut garder l'ancienne version en mémoire.

Collections, crédits, boosters, favoris et profils sont conservés : rien n'est stocké dans le fichier.

**Quand faut-il relancer le SQL ?** Seulement si je vous le dis. Le script est conçu pour être relancé sans danger : il ne supprime aucune donnée, il recrée les tables manquantes et remet les droits et les règles en place.

**Quand faut-il vider le marché ?** Quand je modifie le fonctionnement des enchères ou des échanges, comme pour le passage aux propositions à valider. Les annonces créées avec l'ancien format ne sont plus lisibles par la nouvelle version. Avant ou après le déploiement, exécutez :

```sql
delete from public.docs where coll = 'market';
```

Les cartes bloquées dans ces annonces ne sont pas perdues : à la reconnexion de chaque joueur, le jeu constate que l'annonce a disparu et lui rend sa carte automatiquement, en moins d'une minute. Les crédits bloqués dans une enchère reviennent de la même façon.

**Ne supprimez jamais** les lignes `coll = 'players'` : ce sont les collections de vos joueurs.

**Revenir en arrière :** Netlify garde l'historique. Onglet **Deploys**, ouvrez un déploiement précédent et cliquez sur **Publish deploy** pour le remettre en ligne.

## Dépannage

**« Sauvegarde en ligne indisponible » ou « Partie locale »**

Ouvrez l'onglet **Profil** : la ligne de diagnostic indique désormais le message d'erreur exact renvoyé par Supabase. Les causes habituelles :

| Message | Cause | Solution |
|---|---|---|
| Table « docs » introuvable | Le script SQL n'a pas été exécuté jusqu'au bout | Relancez-le et vérifiez les trois lignes `... OK` à la fin |
| `permission denied for table docs` | Le rôle `authenticated` n'a pas les droits sur la table | Relancez le script SQL : sa section 5 accorde ces droits |
| Écriture refusée, `row-level security` | Les règles n'ont pas été créées | Relancez le script SQL en entier |
| `Invalid API key` | Clé incorrecte dans le fichier | Recopiez la clé `anon` depuis Supabase |
| `Failed to fetch` | Adresse de projet erronée, ou projet en pause | Vérifiez l'adresse, et réveillez le projet depuis le tableau de bord Supabase |

Le classement ne montre que les joueurs réellement enregistrés en ligne. Tant qu'une partie est en « Partie locale », elle n'y figure pas : c'est normal.

**Un testeur ne voit pas les autres :** demandez-lui d'ouvrir son Profil. S'il est en « Partie locale », le message d'erreur vous dira pourquoi.

**Le projet Supabase se met en pause** après une semaine sans activité. Une visite du tableau de bord suffit à le relancer.

## Gérer l'alpha au quotidien

Dans Supabase > **SQL Editor** :

```sql
-- voir les joueurs
select path, data->>'pseudo' as pseudo, data->>'unique' as pokemon, data->>'credits' as credits
from public.docs where coll = 'players';

-- libérer une place
delete from public.docs where path = 'players/<uuid-du-joueur>';

-- tout remettre à zéro
delete from public.docs;
```

Pour supprimer aussi le compte d'un testeur : **Authentication** > **Users**.

---

## Limites connues

- **Sécurité :** la logique du jeu tourne dans le navigateur. Un joueur à l'aise techniquement pourrait s'attribuer des crédits ou des cartes. Acceptable pour une alpha entre amis ; à déplacer côté serveur (Supabase Edge Functions) avant une ouverture publique.
- **Paiements :** les offres en euros sont désactivées, et les offres uniques sont gratuites pendant l'alpha (`const ALPHA_FREE=true;` dans le fichier).
- **Visuels :** les cartes n'ont pas les illustrations officielles. Quand vous aurez vos images, renseignez `const IMG_URL="/images/pokemon/{id}.png";`. Attention aux droits : ces visuels appartiennent à Nintendo, Game Freak et The Pokémon Company.
