# ============================================================
#  DexCraft — autres formes : formes alternatives de Pokémon ordinaires et Ursaking Lune Vermeille (1.1.7, 8001 à 8035),
#  formes des légendaires et fabuleux (1.1.8, 8036 à 8070 : variantes, transformations, fusions)
#  Numéros 8001 et suivants, genre « forme ». Depuis PokeAPI : nom français de l'espèce et de la forme, catégorie,
#  types, taille, poids, statistiques, illustrations officielles normale et shiny.
#  Écrit outils\formes-autres.js.txt (lignes à coller dans l'objet FORMS d'index.html) et les images :
#  images\<n°>.webp et images\shiny\<n°>.webp (PNG d'origine dans images-png\ et images-shiny-png\, ignorés par git).
#
#    powershell -ExecutionPolicy Bypass -File outils\formes-autres.ps1
#
#  Rareté : celle du Pokémon d'origine (remplie dans index.html, comme les formes régionales).
#  Relançable : les images déjà présentes sont gardées. L'ordre de la liste fixe les numéros : n'ajouter qu'à la fin.
# ============================================================
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$racine = Split-Path -Parent $PSScriptRoot
$API = "https://pokeapi.co/api/v2"

# nom PokeAPI | étiquette courte (à côté du numéro) | nom affiché sur la carte (facultatif : sinon espèce + forme)
$LISTE = @"
ursaluna-bloodmoon|Lune Vermeille
lycanroc-midnight|Nocturne
lycanroc-dusk|Crépusculaire
oricorio-pom-pom|Pom-Pom
oricorio-pau|Hula
oricorio-sensu|Buyō
rotom-heat|Chaleur|Motisma Chaleur
rotom-wash|Lavage|Motisma Lavage
rotom-frost|Froid|Motisma Froid
rotom-fan|Hélice|Motisma Hélice
rotom-mow|Tonte|Motisma Tonte
castform-sunny|Solaire
castform-rainy|Eau de Pluie
castform-snowy|Blizzard
wormadam-sandy|Sable
wormadam-trash|Déchet
basculin-blue-striped|Bleu
basculin-white-striped|Blanc
toxtricity-low-key|Grave
floette-eternal|Éternelle
squawkabilly-blue-plumage|Bleu
squawkabilly-yellow-plumage|Jaune
squawkabilly-white-plumage|Blanc
tatsugiri-droopy|Affalée
tatsugiri-stretchy|Raide
dudunsparce-three-segment|Triple
maushold-family-of-three|Trois
gimmighoul-roaming|Marche
minior-red|Rouge
minior-orange|Orange
minior-yellow|Jaune
minior-green|Vert
minior-blue|Bleu
minior-indigo|Indigo
minior-violet|Violet
deoxys-attack|Attaque
deoxys-defense|Défense
deoxys-speed|Vitesse
giratina-origin|Originelle
shaymin-sky|Céleste
tornadus-therian|Totémique
thundurus-therian|Totémique
landorus-therian|Totémique
enamorus-therian|Totémique
keldeo-resolute|Décidé
meloetta-pirouette|Danse
hoopa-unbound|Déchaîné|Hoopa Déchaîné
zygarde-10|10 %
magearna-original|Couleur du Passé
zarude-dada|Papa
ogerpon-wellspring-mask|Puits
ogerpon-hearthflame-mask|Fourneau
ogerpon-cornerstone-mask|Pierre
dialga-origin|Originelle
palkia-origin|Originelle
kyurem-black|Noir|Kyurem Noir
kyurem-white|Blanc|Kyurem Blanc
necrozma-dusk|Couchant
necrozma-dawn|Aurore
necrozma-ultra|Ultra|Ultra-Necrozma
calyrex-ice|Cavalier du Froid
calyrex-shadow|Cavalier d’Effroi
zacian-crowned|Suprême
zamazenta-crowned|Suprême
kyogre-primal|Primo|Primo-Kyogre
groudon-primal|Primo|Primo-Groudon
eternatus-eternamax|Infinimax
zygarde-complete|Parfaite
terapagos-terastal|Téracristal
terapagos-stellar|Stellaire
"@ -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_.Trim().Split("|"); [pscustomobject]@{ nom = $p[0]; tag = $p[1]; affiche = if ($p.Count -gt 2) { $p[2] } else { "" } } }

$TYPE_NUM = @{ normal=1; fighting=2; flying=3; poison=4; ground=5; rock=6; bug=7; ghost=8; steel=9; fire=10; water=11; grass=12; electric=13; psychic=14; ice=15; dragon=16; dark=17; fairy=18 }
$GEN = @{ "generation-i"=1; "generation-ii"=2; "generation-iii"=3; "generation-iv"=4; "generation-v"=5; "generation-vi"=6; "generation-vii"=7; "generation-viii"=8; "generation-ix"=9 }
$fr = { param($liste) ($liste | Where-Object { $_.language.name -eq "fr" } | Select-Object -First 1).name }
$pngN = Join-Path $racine "images-png"; $pngS = Join-Path $racine "images-shiny-png"
New-Item -ItemType Directory -Force $pngN, $pngS, (Join-Path $racine "images\shiny") | Out-Null

function Image($url, $png, $webp) {
  if (Test-Path $webp) { return }
  if (-not $url) { Write-Host "  illustration absente de PokeAPI : $webp" -ForegroundColor Yellow; return }
  if (-not (Test-Path $png)) { Invoke-WebRequest $url -OutFile $png -UseBasicParsing }
  & magick $png -resize 256x256 -quality 80 $webp
}

$n = 8000; $lignes = @(); $especes = @{}
foreach ($f in $LISTE) {
  $n++
  $p = Invoke-RestMethod "$API/pokemon/$($f.nom)"
  $base = [int]($p.species.url.TrimEnd("/").Split("/")[-1])
  if (-not $especes.ContainsKey($base)) { $especes[$base] = Invoke-RestMethod "$API/pokemon-species/$base" }
  $e = $especes[$base]
  $forme = Invoke-RestMethod $p.forms[0].url
  $nomEsp = & $fr $e.names; $fn = & $fr $forme.form_names
  $nom = if ($f.affiche) { $f.affiche } else { "$nomEsp $fn" }
  $cat = ($e.genera | Where-Object { $_.language.name -eq "fr" } | Select-Object -First 1).genus
  $stats = @("hp","attack","defense","special-attack","special-defense","speed") | ForEach-Object { $s = $_; ($p.stats | Where-Object { $_.stat.name -eq $s }).base_stat }
  $typs = @($p.types | Sort-Object slot | ForEach-Object { $TYPE_NUM[$_.type.name] })
  $g = $GEN[$e.generation.name]
  Image $p.sprites.other.'official-artwork'.front_default (Join-Path $pngN "$n.png") (Join-Path $racine "images\$n.webp")
  Image $p.sprites.other.'official-artwork'.front_shiny (Join-Path $pngS "$n.png") (Join-Path $racine "images\shiny\$n.webp")
  $q = { param($t) $t -replace '"', '\"' }
  $lignes += "  ${n}:[""$(& $q $nom)"",""$(& $q $cat)"",$g,[$($typs -join ',')],$($p.height),$($p.weight),[$($stats -join ',')],null,{base:$base,kind:""forme"",tag:""$(& $q $f.tag)"",fn:""$(& $q $fn)""}]"
  Write-Host "$n  $($f.nom) -> $nom ($fn)"
  Start-Sleep -Milliseconds 100
}
Set-Content (Join-Path $PSScriptRoot "formes-autres.js.txt") (($lignes -join ",`n") + "`n") -Encoding UTF8
Write-Host "outils\formes-autres.js.txt écrit ($($lignes.Count) cartes)."
