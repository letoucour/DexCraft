# DexCraft — mémoire du projet

Ce fichier remplace l'historique des conversations. Toute session Claude Code doit le lire en premier, puis `index.html`.

## 1. Le projet en deux phrases

DexCraft est un jeu de collection de cartes Pokémon en français, inspiré de wiki-masters.com : on ouvre des boosters, on complète une collection, on échange et on vend aux enchères entre joueurs. Il tourne actuellement en alpha privée, sans limite de joueurs.

**Propriétaire du projet :** Theo (theo.lostria@gmail.com), administrateur du jeu.

## 2. Architecture

- **`index.html`** : tout le jeu, environ 2 500 lignes, souvent très longues (les données `DEX` et `EVO` tiennent chacune sur une seule ligne). HTML, CSS et JavaScript dans un seul fichier, sans dépendance à part `supabase-js` chargé depuis un CDN.
- **Hébergement** : GitHub Pages, branche `main`, racine du dépôt. Chaque commit redéploie le site.
- **Base de données** : Supabase (projet `hxrbzhmzjeuhmaioqhdd`). Comptes e-mail et mot de passe, une seule table `docs` avec les colonnes `path`, `coll`, `data` (jsonb), `lease_holder`, `lease_until`, `updated_at`. Une table `admins`. Le script complet est dans `dexcraft-supabase.sql`.
- **Chemins de données** : `players/<uuid>` pour un profil, `market/<id>` pour une annonce.
- **Couche d'accès** : l'objet `db` imite l'API des artefacts Claude (`doc().get/set/update/delete/acquire`, `collection().onSnapshot`). Pour changer de back-end, il suffit de réécrire `makeDb`.

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
- Ouverture par 1, 5, 10, 20, 50 ou 100. À partir de 20, le mode « Aller aux Hits » s'active tout seul.
- Évolution : 3 exemplaires d'un Pokémon donnent 1 carte de son évolution, ou d'une de ses méga-évolutions. « Évolution rapide » traite d'un coup tous les Pokémon possédés à 4 exemplaires ou plus dont l'évolution manque.
- Maximum 10 enchères simultanées par joueur.
- Boutique : `ALPHA_FREE = true` rend les offres uniques gratuites pendant les phases de test. Les paiements en euros sont désactivés, un bandeau rouge l'annonce.

### Marché

- **Enchères** : la carte est mise de côté chez le vendeur, les crédits de l'enchérisseur sont bloqués et rendus dès qu'il est dépassé.
- **Échanges** : le proposant met sa carte de côté, et c'est le propriétaire de l'annonce qui accepte ou refuse. Trois types de demande : n'importe quelle carte de la rareté, n'importe laquelle **qui lui manque** (valeur par défaut), ou un Pokémon précis.
- **Règle d'or du marché** : un joueur n'écrit que dans son propre profil. Tout transfert passe par une annonce et par la fonction `settle()`, qui rend les cartes et crédits dus. Si une annonce disparaît, la carte revient à son propriétaire après une minute. Ne jamais écrire directement dans le profil d'un autre joueur, sauf outils administrateur.

## 4. Interface, décisions prises

- Ouverture de booster : main de cartes en éventail, défilement horizontal, carte centrale mise en avant.
- Animations par rareté, de plus en plus fortes : rien en Commune, reflet vert en Peu commune, bleu en Rare, gerbe violette en Épique, turquoise en Méga, scène plein écran en Légendaire, fanfare et feux d'artifice en Mythique, scène argentée la plus longue en Transcendante.
- Dos de carte : bleu par défaut, rouge en Mythique, métallisé gris en Transcendante.
- Sons synthétisés dans le navigateur, aucun fichier audio. Bouton de coupure dans l'en-tête.
- Classement : trié par cartes différentes, Pokémon et mégas confondus. Barre segmentée par rareté, sur 1 118 cartes. Mythiques et transcendantes affichées en pastilles ✦ et ❖, hors classement. Le détail par rareté porte une version (`BYR_V`) : l'incrémenter à chaque changement d'ordre des raretés.
- Favoris : protégés de la défausse, retirés automatiquement si la carte quitte la collection.
- Mode développeur : bloc en bas du profil, visible pour les adresses de `ADMIN_EMAILS`, actif seulement si l'interrupteur est allumé. Outils : test des animations mythique et transcendante, crédits et boosters à un joueur, badge Alpha testeur, changement de pseudo, réinitialisation de la collection ou du profil, vidage du marché avec restitution des cartes et crédits.

## 5. Contraintes permanentes

- **Tout en français**, y compris les messages d'erreur et les commentaires de code.
- **Ne jamais dévoiler** l'existence des mythiques et des transcendantes dans un texte visible par un joueur qui n'en possède pas.
- **Aucune illustration officielle** n'est intégrée. La variable `IMG_URL` vaut `""` (désactivée). Pour brancher les visuels, la passer à `"images/{id}.png"` ; `{id}` est remplacé par le numéro de la carte, et `dexcraft-images.json` donne la correspondance des 1 127 fichiers attendus. Les visuels appartiennent à Nintendo, Game Freak et The Pokémon Company : à remplacer par des créations originales avant toute ouverture publique.
- **La logique tourne dans le navigateur.** Un joueur à l'aise techniquement peut tricher. À déplacer côté serveur (fonctions Supabase) avant un lancement public, en priorité les tirages, les crédits et les transferts.
- **Compatibilité des données** : un changement de format des annonces impose de vider le marché avec `delete from public.docs where coll = 'market';`. Ne jamais supprimer les lignes `coll = 'players'`.

## 6. Chantiers ouverts

1. Découper `index.html` en modules : données, cartes, marché, animations, interface.
2. Intégrer les visuels des cartes quand ils seront disponibles.
3. Passer les tirages et les transactions côté serveur.
4. Brancher un paiement réel, puis remettre `ALPHA_FREE = false`.

## 7. Comment travailler sur ce dépôt

- Modifier `index.html` directement, en gardant le style du code existant : fonctions courtes, chaînes en français, pas de dépendance nouvelle.
- Après chaque modification, vérifier au minimum : ouverture d'un booster, collection, évolutions, enchères, échanges, profil.
- Commit en français, une phrase claire décrivant le changement. Le push sur `main` déclenche le déploiement GitHub Pages.
- Prévenir les testeurs de recharger avec Ctrl + F5.
