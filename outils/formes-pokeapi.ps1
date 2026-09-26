# ============================================================
#  DexCraft — données des formes régionales et Gigamax, depuis PokeAPI
#  Écrit outils\formes.json : pour chaque forme, nom français, catégorie, types, taille,
#  poids, statistiques, numéro du Pokémon d'origine et adresse de l'illustration officielle.
#
#    powershell -ExecutionPolicy Bypass -File outils\formes-pokeapi.ps1
# ============================================================
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$racine = Split-Path -Parent $PSScriptRoot
$API = "https://pokeapi.co/api/v2"

# nom PokeAPI | genre de forme | précision ajoutée au nom français (facultative)
$FORMES = @"
rattata-alola|alola
raticate-alola|alola
raichu-alola|alola
sandshrew-alola|alola
sandslash-alola|alola
vulpix-alola|alola
ninetales-alola|alola
diglett-alola|alola
dugtrio-alola|alola
meowth-alola|alola
persian-alola|alola
geodude-alola|alola
graveler-alola|alola
golem-alola|alola
grimer-alola|alola
muk-alola|alola
exeggutor-alola|alola
marowak-alola|alola
meowth-galar|galar
ponyta-galar|galar
rapidash-galar|galar
slowpoke-galar|galar
slowbro-galar|galar
farfetchd-galar|galar
weezing-galar|galar
mr-mime-galar|galar
articuno-galar|galar
zapdos-galar|galar
moltres-galar|galar
slowking-galar|galar
corsola-galar|galar
zigzagoon-galar|galar
linoone-galar|galar
darumaka-galar|galar
darmanitan-galar-standard|galar
yamask-galar|galar
stunfisk-galar|galar
growlithe-hisui|hisui
arcanine-hisui|hisui
voltorb-hisui|hisui
electrode-hisui|hisui
typhlosion-hisui|hisui
qwilfish-hisui|hisui
sneasel-hisui|hisui
samurott-hisui|hisui
lilligant-hisui|hisui
zorua-hisui|hisui
zoroark-hisui|hisui
braviary-hisui|hisui
sliggoo-hisui|hisui
goodra-hisui|hisui
avalugg-hisui|hisui
decidueye-hisui|hisui
wooper-paldea|paldea
tauros-paldea-combat-breed|paldea|Race Combative
tauros-paldea-blaze-breed|paldea|Race Flamboyante
tauros-paldea-aqua-breed|paldea|Race Aquatique
venusaur-gmax|gmax
charizard-gmax|gmax
blastoise-gmax|gmax
butterfree-gmax|gmax
pikachu-gmax|gmax
meowth-gmax|gmax
machamp-gmax|gmax
gengar-gmax|gmax
kingler-gmax|gmax
lapras-gmax|gmax
eevee-gmax|gmax
snorlax-gmax|gmax
garbodor-gmax|gmax
melmetal-gmax|gmax
rillaboom-gmax|gmax
cinderace-gmax|gmax
inteleon-gmax|gmax
corviknight-gmax|gmax
orbeetle-gmax|gmax
drednaw-gmax|gmax
coalossal-gmax|gmax
flapple-gmax|gmax
appletun-gmax|gmax
sandaconda-gmax|gmax
toxtricity-amped-gmax|gmax
centiskorch-gmax|gmax
hatterene-gmax|gmax
grimmsnarl-gmax|gmax
alcremie-gmax|gmax
copperajah-gmax|gmax
duraludon-gmax|gmax
urshifu-single-strike-gmax|gmax|Style Poing Final
urshifu-rapid-strike-gmax|gmax|Style Mille Poings
"@ -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_.Trim().Split("|"); [pscustomobject]@{ nom = $p[0]; genre = $p[1]; prec = if ($p.Count -gt 2) { $p[2] } else { "" } } }

$TYPES = @{ normal=1; fighting=2; flying=3; poison=4; ground=5; rock=6; bug=7; ghost=8; steel=9; fire=10; water=11; grass=12; electric=13; psychic=14; ice=15; dragon=16; dark=17; fairy=18 }
$SUFFIXE = @{ alola = " d" + [char]0x2019 + "Alola"; galar = " de Galar"; hisui = " de Hisui"; paldea = " de Paldea"; gmax = " Gigamax" }
$especes = @{}
$sortie = foreach ($f in $FORMES) {
  $p = Invoke-RestMethod "$API/pokemon/$($f.nom)"
  $id = [int]($p.species.url.TrimEnd("/").Split("/")[-1])
  if (-not $especes.ContainsKey($id)) { $especes[$id] = Invoke-RestMethod "$API/pokemon-species/$id"; Start-Sleep -Milliseconds 120 }
  $e = $especes[$id]
  $nomFr = ($e.names | Where-Object { $_.language.name -eq "fr" } | Select-Object -First 1).name
  $genre = ($e.genera | Where-Object { $_.language.name -eq "fr" } | Select-Object -First 1).genus
  $nom = $nomFr + $SUFFIXE[$f.genre] + $(if ($f.prec) { " ($($f.prec))" } else { "" })
  $stats = @("hp","attack","defense","special-attack","special-defense","speed") | ForEach-Object { $n = $_; ($p.stats | Where-Object { $_.stat.name -eq $n }).base_stat }
  [pscustomobject]@{
    nom = $f.nom; genre = $f.genre; base = $id; nomFr = $nom; categorie = $genre
    types = @($p.types | Sort-Object slot | ForEach-Object { $TYPES[$_.type.name] })
    taille = $p.height; poids = $p.weight; stats = @($stats)
    image = $p.sprites.other.'official-artwork'.front_default
  }
  Write-Host "$($f.nom) -> $nom"
  Start-Sleep -Milliseconds 120
}
$sortie | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $PSScriptRoot "formes.json") -Encoding UTF8
Write-Host "outils\formes.json écrit ($(@($sortie).Count) formes)."
