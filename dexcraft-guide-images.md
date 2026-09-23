# DexCraft — guide des images de cartes

Objectif : récupérer une illustration pour chacune des 1 127 cartes, l'alléger, puis l'afficher dans le jeu. Tout est prêt côté jeu : les images s'affichent dans la zone colorée de chaque carte, et dans les images de profil. Une carte sans image garde son affichage actuel (initiale et numéro), donc on peut brancher les images petit à petit.

---

## 0. À lire avant de commencer : les droits

Les illustrations officielles appartiennent à Nintendo, Game Freak et The Pokémon Company. DexCraft est maintenant en **bêta ouverte**, donc accessible à tout le monde. Mettre plus de mille illustrations officielles sur un site public expose le projet à une demande de retrait : Nintendo en envoie régulièrement aux jeux de fans, et GitHub supprime alors le dépôt ou le site.

C'est ta décision. Les options, de la plus prudente à la plus exposée :

1. Garder les cartes sans image, comme aujourd'hui.
2. Utiliser des créations originales (les tiennes, ou celles d'un artiste qui t'en donne le droit).
3. Utiliser les illustrations officielles en connaissant le risque, et être prêt à les retirer vite si une demande arrive.

La suite du guide fonctionne de la même façon quelle que soit la source des images : il suffit que chaque fichier porte le bon nom.

---

## 1. Ce que le jeu attend

- Un dossier **`images`** à la racine du dépôt, à côté de `index.html`.
- Un fichier par carte, nommé **par le numéro de la carte** : `1.png` pour Bulbizarre, `4002.png` pour Méga-Dracaufeu X, `2001.png` pour Mewtwo en Armure, etc.
- La liste complète des 1 127 fichiers, avec le nom de chaque carte, est dans **`dexcraft-images.json`** :
  - 1 025 Pokémon : `1.png` à `1025.png`
  - 93 méga-évolutions : `4001.png` à `4093.png`
  - 5 mythiques : `2001.png` à `2005.png`
  - 4 transcendantes : `3001.png` à `3004.png`
- Idéalement une image **carrée, fond transparent**, le Pokémon centré.

---

## 2. Télécharger automatiquement 1 117 images

Le script **`outils/telecharger-images.ps1`** lit `dexcraft-images.json` et télécharge chaque illustration depuis PokeAPI, une base de données Pokémon libre dont les images sont hébergées sur GitHub.

- Pokémon 1 à 1025 : illustration officielle directe.
- Méga-évolutions : le script interroge l'API PokeAPI pour trouver la bonne forme (X, Y, Z…), puis son illustration.
- Mythiques et transcendantes : ce sont des cartes propres à DexCraft, il n'existe aucune source. Voir l'étape 3.

J'ai testé le script en mode essai sur les 1 127 cartes : **1 117 images sont trouvées**, 10 manquent (voir l'étape 3).

### Option A : tu me demandes de le lancer

Dis-moi « lance le téléchargement des images ». Je lancerai le script et je te montrerai le résultat. Je te demanderai une confirmation avant, parce que ça télécharge environ 1 100 fichiers sur ton PC.

### Option B : tu le lances toi-même

1. Ouvre un terminal PowerShell dans le dossier du jeu :
   ```
   cd C:\DexCraft
   ```
2. Fais d'abord un essai, qui n'écrit rien sur le disque :
   ```
   powershell -ExecutionPolicy Bypass -File outils\telecharger-images.ps1 -Essai -Seulement "1,6,4002,4046"
   ```
   Tu dois voir 4 lignes `ESSAI` avec une adresse chacune.
3. Lance le téléchargement complet :
   ```
   powershell -ExecutionPolicy Bypass -File outils\telecharger-images.ps1
   ```
   Compte 5 à 10 minutes. Chaque image affiche une ligne `OK`. Les lignes jaunes `MANQUE` sont normales pour les 10 cartes de l'étape 3.
4. Si le script s'arrête en route (coupure réseau…), relance simplement la même commande : les images déjà téléchargées sont sautées.

À la fin, le script écrit le détail des images manquantes dans `outils\images-manquantes.csv` (ce fichier n'est pas envoyé sur GitHub).

---

## 3. Les 10 images à fournir à la main

| Fichier | Carte | Pourquoi |
|---|---|---|
| `4092.png` | Méga-Nigirigon | Existe dans PokeAPI, mais sans illustration pour l'instant |
| `2001.png` | Mewtwo en Armure | Carte mythique propre à DexCraft |
| `2002.png` | Pikachu Surfeur | Carte mythique propre à DexCraft |
| `2003.png` | Pikachu Volant | Carte mythique propre à DexCraft |
| `2004.png` | Dracolosse Postier | Carte mythique propre à DexCraft |
| `2005.png` | Sachanobi | Carte mythique propre à DexCraft |
| `3001.png` | Dresseur Red | Carte transcendante |
| `3002.png` | Dresseuse Cynthia | Carte transcendante |
| `3003.png` | Neos en Peignoir | Carte transcendante |
| `3004.png` | Créateur TheoToucour | Carte transcendante |

Pour chacune : une image carrée, de préférence 512 × 512 pixels ou plus, fond transparent si possible, enregistrée en PNG sous le nom exact de la colonne « Fichier », dans le dossier `images`.

Pour Méga-Nigirigon, tu peux aussi relancer le script dans quelques semaines : dès que PokeAPI ajoute l'illustration, il la trouvera tout seul.

Tant qu'une image manque, la carte s'affiche comme aujourd'hui : rien ne casse.

---

## 4. Alléger les images (fortement conseillé)

Les illustrations officielles font environ 475 × 475 pixels en PNG : compte plusieurs centaines de mégaoctets pour l'ensemble. C'est lourd pour le dépôt GitHub et lent à charger pour les joueurs. Les cartes n'ont pas besoin de plus de 256 pixels.

1. Installe ImageMagick (gratuit) :
   ```
   winget install ImageMagick.ImageMagick
   ```
   Puis ferme et rouvre le terminal.
2. Mets les PNG d'origine de côté (ce dossier n'est pas envoyé sur GitHub), puis convertis-les en WebP 256 × 256 dans `images` :
   ```
   cd C:\DexCraft
   New-Item -ItemType Directory -Force images-png
   Move-Item images\*.png images-png\
   magick mogrify -path images -resize 256x256 -quality 80 -format webp images-png\*.png
   ```
   Chaque `images-png\1.png` donne `images\1.webp`.
3. Génère la planche de contrôle, puis ouvre `outils\planche-images.html` dans ton navigateur :
   ```
   powershell -ExecutionPolicy Bypass -File outils\planche-images.ps1
   ```
   Elle montre chaque image avec son numéro, son nom et son poids. Les filtres « Méga » et « Manquantes », la recherche et le fond en damier (pour voir la transparence) aident à repérer une erreur.

Si tu préfères garder les PNG, saute cette étape : il suffira d'indiquer `.png` au lieu de `.webp` à l'étape 5.

---

## 5. Afficher les images dans le jeu

Je peux le faire pour toi : dis-moi simplement que les images sont dans le dossier `images`.

Si tu veux le faire toi-même, c'est une ligne dans `index.html`. Remplace :
```
const IMG_URL="";
```
par :
```
const IMG_URL="images/{id}.webp";
```
(ou `.png` si tu as gardé les PNG). `{id}` est remplacé par le numéro de la carte.

Attention : pas de `/` au début. Le site est publié sous `letoucour.github.io/DexCraft/`, et `"/images/…"` chercherait les images à la racine de `letoucour.github.io`, où elles n'existent pas.

---

## 6. Tester, puis mettre en ligne

1. Ouvre `index.html` dans ton navigateur, puis la Collection : les cartes que tu possèdes doivent montrer leur illustration. Les cartes manquantes restent en « ??? », sans image : on ne dévoile rien.
2. Vérifie aussi une carte mythique ou transcendante si tu en as une, et ton image de profil.
3. Quand tout va bien, demande-moi de faire le commit et le push. Le dossier `images` part avec, et GitHub Pages le publie avec le reste.
4. Préviens les joueurs de recharger avec Ctrl + F5.

---

## 7. Plus tard : ajouter ou remplacer une image

- **Remplacer** une image : dépose le nouveau fichier avec le même nom dans `images`, puis commit et push.
- **Nouvelle carte mythique ou transcendante** : elle aura un nouveau numéro (`2006`, `3005`…). Ajoute l'image `2006.webp` et une ligne dans `dexcraft-images.json` pour garder la liste à jour.
- Les joueurs qui ont déjà l'ancienne image en cache la verront changer après un Ctrl + F5.
