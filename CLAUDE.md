# DexCraft — mémoire du projet

Ce fichier remplace l'historique des conversations. Toute session Claude Code doit le lire en premier, puis `index.html`.

## 1. Le projet en deux phrases

DexCraft est un jeu de collection de cartes Pokémon en français, inspiré de wiki-masters.com : on ouvre des boosters, on complète une collection, on échange et on vend aux enchères entre joueurs. Il tourne actuellement en bêta ouverte (version affichée en bas à gauche), sans limite de joueurs.

**Propriétaire du projet :** Theo (theo.lostria@gmail.com), administrateur du jeu.

## 2. Architecture

- **`index.html`** : tout le jeu, environ 2 500 lignes, souvent très longues (les données `DEX` et `EVO` tiennent chacune sur une seule ligne). HTML, CSS et JavaScript dans un seul fichier, sans dépendance à part `supabase-js` chargé depuis un CDN.
- **Hébergement** : GitHub Pages, branche `main`, racine du dépôt. Chaque commit redéploie le site.
- **Base de données** : Supabase (production `hxrbzhmzjeuhmaioqhdd`, test `thgyzfjozfhwefrztjfh`). Comptes e-mail et mot de passe. Table `docs` (`path`, `coll`, `data` jsonb, `updated_at`), table `admins`, table `game_config` (données du jeu pour le serveur), table `vb_rounds` (plateaux cachés de la VoltoBataille).
- **Scripts SQL, dans l'ordre** : `dexcraft-supabase.sql` (tables et droits), `dexcraft-config.sql` (généré par `outils/generer-config.ps1` depuis `index.html?export-config` : à régénérer et relancer après tout changement de cartes, raretés, boutique ou VoltoBataille), `dexcraft-serveur.sql` puis `dexcraft-serveur-2.sql` (fonctions du jeu, en deux parties : l'éditeur SQL de Supabase a tronqué le fichier unique d'environ 48 000 caractères ; garder chaque script sous 40 000 caractères, et chaque partie révoque elle-même les droits de ses fonctions). `migration-0.4.0.sql` : une seule fois, lors du passage à la 0.4.0.
- **Chemins de données** : `players/<uuid>` pour un profil, `market/<id>` pour une annonce.
- **Le serveur est l'arbitre (depuis la 0.4.0)** : les joueurs ne peuvent QUE LIRE `docs`. Toute modification passe par une fonction SQL `dc_*` (`security definer`), appelée via `rpc(name, args)` dans `index.html`, qui renvoie le profil à jour. Hasard tiré côté serveur (`dc__rnd`, `gen_random_bytes`). Champs calculés par `dc__stamp` : `unique`, `byr`, `total`, `myth`, `trans`, `masterTs`, `beta`, `stats.maxCr`, `stats.days`. Les fonctions `dc__*` sont internes (non exécutables par les joueurs). Pour une nouvelle action : écrire une fonction `dc_*` qui vérifie tout, la tester sur PostgreSQL local, jamais d'écriture directe depuis le navigateur.
- **Tests** : sur ce PC (`localhost`, `127.0.0.1` ou fichier ouvert), `index.html` se branche automatiquement sur le projet Supabase de **test** (« BASE DE TEST » en bas à gauche). `outils/serveur-local.ps1` sert le jeu sur http://localhost:8123 et http://127.0.0.1:8123 (deux sessions, deux comptes). Comptes de test : `theo.lostria+test1@gmail.com` (admin) et `+test2`. PostgreSQL 17 est installé sur le PC pour tester le SQL hors ligne.
- **Couche de lecture** : l'objet `db` (`collection().onSnapshot`) lit `docs` et suit les changements en temps réel.

## 3. Règles du jeu, à ne pas casser

### Raretés, dans l'ordre des indices 0 à 7

| Indice | Rareté | Taux par carte | Défausse | Prix de départ conseillé |
|---|---|---|---|---|
| 0 | Commune | 53,7634 % (le reste) | 2 | 20 |
| 1 | Peu commune | 26,6 % | 5 | 40 |
| 2 | Rare | 11,7 % | 10 | 100 |
| 3 | Épique | 4,9 % | 15 | 300 |
| 4 | Méga-évolution | 2 % | 18 | 600 |
| 5 | Légendaire | 1 % | 20 | 1 000 |
| 6 | Mythique | 1 sur 4 096 | 50 | 5 000 |
| 7 | Transcendante | 1 sur 8 192 | 100 | 15 000 |

- Le tirage se fait sur `SCALE = 8 192 000` pour que 1/4096 et 1/8192 tombent juste. Le total doit toujours faire exactement `SCALE`.
- Les 2 % des Mégas ont été pris sur les quatre premières raretés : 1,2 point aux Communes, 0,4 aux Peu communes, 0,3 aux Rares, 0,1 aux Épiques.
- **Ajouter une carte mythique ou transcendante ne change jamais le taux global de sa rareté**, seulement la répartition à l'intérieur.
- Le tirage ne dépend jamais de la collection du joueur. `rnd()` élimine le biais de modulo par rejet.

### Cartes

- 1 à 1025 : les Pokémon, données dans `DEX` (nom, catégorie, génération, types, taille, poids, statistiques, rareté).
- 4001 à 4093 : les 93 méga-évolutions officielles, dans `MEGA`. Champ `base` = numéro du Pokémon d'origine. **Visibles** dans la collection, affichées en « ??? » tant qu'on ne les a pas, rangées juste après leur Pokémon d'origine (`DEX_ORDER`).
- 2001 à 2005 : mythiques. 3001 à 3004 : transcendantes. **Invisibles** tant qu'on ne les a pas : ni en « ??? », ni dans les filtres, ni dans les tableaux de taux. Ne jamais les révéler dans un texte d'interface.
- La progression des raretés est strictement croissante le long des lignées d'évolution. Toute modification de rareté doit préserver cette règle.

### Économie et rythme

- Nouveau joueur : 3 100 crédits, 10 boosters.
- Un booster gratuit toutes les 10 minutes, réserve de 10 maximum. Les boosters achetés vont dans une réserve séparée (`bonus`), sans limite, et sont consommés après les gratuits.
- Ouverture par 1, 5 ou 10 boosters maximum (`OPEN_OPTS`). Les ouvertures par 20, 50 et 100 ont été retirées.
- Pseudo : un changement tous les 7 jours à partir de la validation (`pseudoTs` dans le profil), après une boîte de confirmation. L'outil administrateur n'est pas soumis au délai.
- Évolution : 3 exemplaires d'un Pokémon donnent 1 carte de son évolution, ou d'une de ses méga-évolutions. « Évolution rapide » traite d'un coup tous les Pokémon possédés à 4 exemplaires ou plus dont l'évolution manque.
- Maximum 10 enchères simultanées par joueur.
- Boutique : `ALPHA_FREE = false`. Le Pack fondateur reste gratuit (`free:true`). Le Pack de démarrage (5 €) et le Pack Wailord (20 €) sont payants, mais les paiements en euros sont désactivés : note « Paiement indisponible pendant la bêta » et boîte « Paiement indisponible » au clic, comme pour les crédits. Un encadré vert rappelle que le jeu se joue entièrement gratuitement et qu'on n'achète que si on peut se le permettre : à garder.

### Marché

- **Enchères** : la carte est mise de côté chez le vendeur, les crédits de l'enchérisseur sont bloqués et rendus dès qu'il est dépassé.
- **Échanges** : le proposant met sa carte de côté, et c'est le propriétaire de l'annonce qui accepte ou refuse. Trois types de demande : n'importe quelle carte de la rareté, n'importe laquelle **qui lui manque** (valeur par défaut), ou un Pokémon précis.
- **Règle d'or du marché** : tout se règle côté serveur, de façon atomique (verrous de lignes). Enchère : `dc_bid` débite l'enchérisseur et rembourse aussitôt celui qui est dépassé ; `dc_auction_settle` clôture une enchère terminée (déclenchée par `settle()` chez le vendeur ou l'acheteur, ou chez n'importe quel joueur une minute après). Échange : `dc_trade_propose` met la carte de côté, `dc_trade_answer` échange les cartes et rend celles des autres propositions, `dc_trade_cancel` rend tout. Le profil n'a plus de `listings` ni d'`escrow` : annonces et crédits engagés se lisent sur le marché (`myAuctionCount`, `myEscrow`).

## 4. Interface, décisions prises

- Ouverture de booster : main de cartes en éventail, défilement horizontal, carte centrale mise en avant. **Performance mobile** : jusqu'à 50 cartes en main (10 boosters). La 3D n'est active que sur la carte en cours de retournement (classe `.flipping`, retirée après 650 ms) ; au repos, dos seul ou face à plat, jamais de `will-change`. Ne pas remettre de 3D ou d'animation permanente sur toutes les cartes de la main : sur téléphone, la mémoire graphique sature et la page se recharge. Pendant une ouverture, `html.revealing` bloque le « tirer pour actualiser ».
- **VoltoBataille** (onglet `volto`, depuis la 0.3.0) : Voltorbe Flip du casino de Johto. 5 × 5 cartes (1, 2, 3 ou Voltorbe), indicateurs de points et de Voltorbe par ligne et colonne, gains = produit des cartes retournées, mode mémo, 8 niveaux (`VB_LEVELS`), montée d'un niveau par victoire, retour au nombre de cartes retournées après une défaite ou un encaissement. Gains versés en crédits dans la limite de `VB_CAP` = 2 000 par jour (barre de progression, remise à zéro à minuit heure du joueur). Profil : `volto = {day, gained, level}`. Manche en cours en mémoire seulement (`VB`). Lien depuis l'écran des boosters : « En attendant vos boosters, une petite VoltoBataille ? ». Son `SFX.boom` pour l'explosion.
- Écran des boosters : bandeau d'aide en bas (« Changez d’image de profil… »), clic vers le profil, masquable par la croix (préférence `dc-hint-profil` dans le navigateur).
- Animations par rareté, de plus en plus fortes : rien en Commune, reflet vert en Peu commune, bleu en Rare, gerbe violette en Épique, turquoise en Méga, scène plein écran en Légendaire, fanfare et feux d'artifice en Mythique, scène argentée la plus longue en Transcendante.
- Dos de carte : bleu par défaut, rouge en Mythique, métallisé gris en Transcendante.
- Reflets des cartes : Rare, bande de reflet bleue ; Épique, halo violet dans le fond de carte et reflet violet ; Légendaire, fond doré avec des lignes holographiques aux couleurs du ou des types (`--c1`, `--c2`) et reflet brillant.
- Échanges : les annonces des autres joueurs d'abord, en tuiles compactes (6 par ligne, 4 puis 3 sur petit écran) ; un clic ouvre la fiche complète (`tradeOpen`). « Mes annonces » est repliée derrière la case « Voir mes annonces », qui signale les propositions à traiter.
- Sons synthétisés dans le navigateur, aucun fichier audio. Bouton de coupure dans l'en-tête.
- Classement : trié par cartes différentes, Pokémon et mégas confondus. Entre Maîtres, le premier à avoir obtenu le titre reste devant (`masterTs`, posé par `stamp`, effacé si le titre est perdu), puis le nombre total de cartes. Barre segmentée par rareté, sur 1 118 cartes. Mythiques et transcendantes affichées en pastilles ✦ et ❖, hors classement. Le détail par rareté porte une version (`BYR_V`) : l'incrémenter à chaque changement d'ordre des raretés.
- Favoris : protégés de la défausse, retirés automatiquement si la carte quitte la collection.
- Mode développeur : bloc en bas du profil, visible pour les adresses de `ADMIN_EMAILS`, actif seulement si l'interrupteur est allumé. Outils : test des animations mythique et transcendante, crédits et boosters à un joueur, badge Alpha testeur, changement de pseudo, réinitialisation de la collection ou du profil, vidage du marché avec restitution des cartes et crédits, et remise à zéro générale (`resetEveryone`, confirmation en tapant RESET) : tous les joueurs repartent avec aucune carte, 3 100 crédits et 10 boosters gratuits, comme un compte neuf, et peuvent de nouveau récupérer une fois chaque offre unique, dont le Pack fondateur. Ils gardent pseudo, titres Alpha et Bêta testeur et mode développeur. Le marché est vidé.
- Titres : tous définis dans le tableau `TITLES` (clé, nom, icône, description, groupe, style, et soit `ids` + `need` à posséder, soit `test`). Obtention recalculée à la volée depuis la collection (`titleEarned`), jamais stockée, sauf `alpha` (à la main) et `beta`. Le joueur choisit **3 titres au plus** dans la section « Titres » du profil (`titles` dans le profil, ordre de sélection) ; sans choix, `TITLE_DEFAULT` (Alpha, Bêta, Maître s'il les a). Affichage à côté du nom (`badgeTag`) : Alpha testeur d'abord, puis Bêta testeur, puis les autres dans l'ordre de sélection. Un titre perdu quitte la sélection (`stamp`).
  - Spéciaux : « ✦ Alpha testeur » (« A aidé au développement en Alpha de DexCraft »), « ◈ Bêta testeur » (tous les joueurs tant que `BETA_OPEN = true`, enregistré dans `beta` ; « A participé à la Bêta ouverte de DexCraft »), « Secret » (au moins une mythique ou transcendante), « Mythique » (toutes les mythiques), « Transcendant » (toutes les transcendantes). Ces trois derniers sont `hidden` : invisibles tant qu'ils ne sont pas obtenus.
  - Pokédex : paliers `DEX_TIERS` sur le nombre de cartes différentes de `DEX_ORDER`, **mégas comprises** : 50 Novice, 151 Gamin, 300 Scout, 450 Ranger, 600 As, 750 Champion, 950 Conseil 4, puis « ♛ Maître » (les 1 118 cartes).
  - Collections : « Starters » (les 27 starters de base, `STARTER_IDS`), et Commun, Peu commun, Rare, Épique, Méga, Légendaire (toutes les cartes de la rareté ; Méga = les 93 méga-évolutions).
  - Régions : « Maître de Kanto » à « Maître de Paldea », tous les Pokémon d'une génération. Types : un titre par type (« Psy », « Feu »…), tous les Pokémon du type. Mégas exclues des régions et des types.
  - Mythiques et transcendantes ne comptent que pour Secret, Mythique et Transcendant.
  - Activité (20 titres) : compteurs `stats` du profil, sans rétroactivité (`bump`). Boosters ouverts (Déballeur 100, Ouvre-boosters 1 000, Accro aux boosters 5 000), évolutions (Éleveur 50, Évolutionniste 250), enchères vendues (Commerçant 10, Marchand 50), enchères remportées (Enchérisseur 10, Collectionneur avisé 50), échanges conclus (Négociant 20, Diplomate 80, Charismatique 200), cartes défaussées (Recycleur 500), crédits détenus d'un coup (Fortuné 50 000, Magnat 250 000, `maxCr` posé par `stamp`), jours de jeu (Fidèle 30, Vétéran 100, `touchDay` dans `mutateMe`), manches de VoltoBataille gagnées (Joueur de casino 50), Chanceux (2 Légendaires dans un booster), Démineur (manche gagnée au niveau 8).
  - Un clic sur un titre affiché à côté d'un nom ouvre « Comment l’obtenir ? » (`titleInfo`). Pour Secret, Mythique et Transcendant, la condition (fenêtre et infobulle) est remplacée par « ??? », sauf si le joueur qui regarde a lui-même ce titre (`titleHow`).

## 5. Contraintes permanentes

- **Tout en français**, y compris les messages d'erreur et les commentaires de code.
- **Ne jamais dévoiler** l'existence des mythiques et des transcendantes dans un texte visible par un joueur qui n'en possède pas.
- **Illustrations** : `IMG_URL = "images/{id}.webp"` (chemin relatif, jamais de `/` au début : le site est sous `/DexCraft/`). Le dossier `images` contient 1 118 WebP 256 × 256 : les 1 025 Pokémon et 93 mégas, illustrations officielles tirées de PokeAPI, sauf Méga-Nigirigon (4092) fournie par Theo. `imgFor` n'affiche **aucune image** pour les mythiques et les transcendantes (rareté 6 et 7) : Theo fournira leurs images plus tard, il faudra alors lever ce blocage. PNG d'origine dans `images-png/` et images fournies dans `images-perso/`, tous deux ignorés par git. Les illustrations officielles appartiennent à Nintendo, Game Freak et The Pokémon Company : risque de demande de retrait, choix assumé par Theo.
- **Anti-triche** : depuis la 0.4.0, le navigateur n'a plus aucun droit d'écriture. Ne jamais réintroduire d'écriture directe dans `docs` depuis `index.html`, ni de calcul de hasard ou de gains côté navigateur : tout passe par `dc_*`.
- **Compatibilité des données** : un changement de format des annonces impose de vider le marché avec `delete from public.docs where coll = 'market';`. Ne jamais supprimer les lignes `coll = 'players'`.

## 6. Chantiers ouverts

1. Découper `index.html` en modules : données, cartes, marché, animations, interface.
2. Images des 9 mythiques et transcendantes, à fournir par Theo dans `images-perso/` (nommées par numéro), puis à convertir et à autoriser dans `imgFor`. Procédure et outils : `dexcraft-guide-images.md`, `outils/telecharger-images.ps1`, `outils/planche-images.ps1` (planche de contrôle), `outils/serveur-local.ps1` (test sur http://localhost:8123). Conversion : `magick in.png -trim +repage -resize 240x240 -background none -gravity center -extent 256x256 -quality 80 images/<id>.webp`.
3. **Version 0.4.0 : anti-triche, en test.** Serveur arbitre en place (voir Architecture). Passage en production : lancer sur le vrai Supabase `dexcraft-supabase.sql`, `dexcraft-config.sql`, `dexcraft-serveur.sql`, `dexcraft-serveur-2.sql` puis `migration-0.4.0.sql`, et pousser aussitôt.
4. Domaine personnalisé (prévu) : GitHub Pages, Settings, Pages, Custom domain, plus DNS chez le registraire, et ajouter l'adresse dans Supabase (Authentication, URL Configuration). L'ancienne adresse redirige ; les joueurs se reconnectent une fois.
5. Brancher un paiement réel (Stripe) pour le Pack de démarrage, le Pack Wailord et les crédits, après la 0.4.0 : Stripe Checkout ou Payment Link, puis webhook vers une fonction Supabase qui crédite le compte côté serveur.

## 7. Comment travailler sur ce dépôt

- Modifier `index.html` directement, en gardant le style du code existant : fonctions courtes, chaînes en français, pas de dépendance nouvelle.
- Après chaque modification, vérifier au minimum : ouverture d'un booster, collection, évolutions, enchères, échanges, profil.
- Commit en français, une phrase claire décrivant le changement. Le push sur `main` déclenche le déploiement GitHub Pages.
- **Version** : `APP_VERSION` dans `index.html`, affichée en bas à gauche. À **chaque push**, monter le dernier chiffre (0.2.1 → 0.2.2 → 0.2.3…), sauf si Theo dit explicitement qu'un ajout mineur ne change pas la version (alors ni version ni patchnote). Mise à jour majeure de la bêta : 0.3.0, puis nouveau cycle. Sortie publique : 1.0.0. Citer la version dans le message de commit.
- Ne pousser que sur signal explicite de Theo (« push »).
- **Patchnote** : à chaque push validé, donner à Theo un patchnote récapitulatif de la version, rédigé pour les joueurs.
- Toujours répondre à Theo en français.
- Prévenir les testeurs de recharger avec Ctrl + F5.
