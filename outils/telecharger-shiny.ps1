# ============================================================
#  DexCraft — téléchargement des illustrations shiny (1.1.0)
#  Source : illustrations officielles shiny du dépôt PokeAPI/sprites (front_shiny de l'API pour les méga-évolutions,
#  formes régionales et Gigamax). PNG d'origine dans images-shiny-png\ (ignoré par git), puis WebP 256 × 256
#  (qualité 80, comme les images normales) dans images\shiny\<n°>.webp.
#  Pas de shiny pour les mythiques et les transcendantes. Zarbi A (201) : l'illustration « par défaut » de PokeAPI
#  est la forme F : image fournie par Theo, comme Méga-Carchacrok Z (4056) et Méga-Nigirigon (4092)
#  (PNG dans images-shiny-png, convertis comme les images perso : -trim, 240 px, cadre de 256 px).
#
#    powershell -ExecutionPolicy Bypass -File outils\telecharger-shiny.ps1
#    powershell -ExecutionPolicy Bypass -File outils\telecharger-shiny.ps1 -Seulement 1,4001,5001,6001,7001
#
#  Relançable : les images déjà présentes sont sautées. Rapport des manquantes : outils\shiny-manquantes.csv
# ============================================================
param([string]$Seulement = "", [int]$Pause = 100)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$racine = Split-Path -Parent $PSScriptRoot
$png    = Join-Path $racine "images-shiny-png"
$webp   = Join-Path $racine "images\shiny"
$rapport = Join-Path $PSScriptRoot "shiny-manquantes.csv"
$ART    = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/shiny"
New-Item -ItemType Directory -Force $png, $webp | Out-Null

# liste des cartes : numéro DexCraft, nom, et comment trouver l'image
$cartes = @()
$images = Get-Content (Join-Path $racine "dexcraft-images.json") -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($c in $images) {
  if ($c.type -eq "pokemon") { $cartes += [pscustomobject]@{ id = [int]$c.id; nom = $c.nom; url = "$ART/$($c.dex).png"; api = $null; mega = $null } }
  elseif ($c.type -eq "mega") { $cartes += [pscustomobject]@{ id = [int]$c.id; nom = $c.nom; url = $null; api = $null; mega = $c } }
}
$formes = Get-Content (Join-Path $PSScriptRoot "formes-ids.json") -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($f in $formes) { $cartes += [pscustomobject]@{ id = [int]$f.id; nom = $f.nom; url = $null; api = $f.nom; mega = $null } }
$lettres = "b c d e f g h i j k l m n o p q r s t u v w x y z exclamation question" -split " "
for ($i = 0; $i -lt $lettres.Count; $i++) { $cartes += [pscustomobject]@{ id = 7001 + $i; nom = "unown-$($lettres[$i])"; url = "$ART/201-$($lettres[$i]).png"; api = $null; mega = $null } }

function Shiny-Api($nom) {
  $fiche = Invoke-RestMethod "https://pokeapi.co/api/v2/pokemon/$nom"
  $u = $fiche.sprites.other.'official-artwork'.front_shiny
  if (-not $u) { throw "$nom existe dans PokeAPI mais sans illustration shiny" }
  return $u
}
function Shiny-Mega($c) {
  $espece = Invoke-RestMethod "https://pokeapi.co/api/v2/pokemon-species/$($c.dex)"
  $megas  = @($espece.varieties | ForEach-Object { $_.pokemon.name } | Where-Object { $_ -match "-mega" })
  $fin    = if ($c.forme) { "-mega-" + $c.forme.ToLower() } else { "-mega" }
  $nom    = $megas | Where-Object { $_.EndsWith($fin) } | Select-Object -First 1
  if (-not $nom) { throw "variante méga absente de PokeAPI (trouvées : $($megas -join ', '))" }
  return Shiny-Api $nom
}

$filtre = @($Seulement -split "[,; ]+" | Where-Object { $_ } | ForEach-Object { [int]$_ })
$manquantes = @(); $ok = 0
foreach ($c in $cartes) {
  if ($filtre.Count -and -not ($filtre -contains $c.id)) { continue }
  $p = Join-Path $png "$($c.id).png"; $w = Join-Path $webp "$($c.id).webp"
  if (Test-Path $w) { $ok++; continue }   # déjà prête (dont les images fournies à la main : 201, 4056, 4092)
  try {
    if ($c.id -eq 201) { throw "Zarbi A : PokeAPI ne donne que la forme F par défaut" }
    if (-not (Test-Path $p)) {
      $url = if ($c.url) { $c.url } elseif ($c.api) { Shiny-Api $c.api } else { Shiny-Mega $c.mega }
      Invoke-WebRequest $url -OutFile $p -UseBasicParsing
      Start-Sleep -Milliseconds $Pause
    }
    if (-not (Test-Path $w)) { & magick $p -resize 256x256 -quality 80 $w; if ($LASTEXITCODE) { throw "conversion WebP impossible" } }
    $ok++
  } catch {
    $r = $_.Exception.Message; if ($r -match "404") { $r = "introuvable (404)" }
    if (Test-Path $p) { if ((Get-Item $p).Length -lt 100) { Remove-Item $p } }
    $manquantes += [pscustomobject]@{ id = $c.id; nom = $c.nom; raison = $r }
    Write-Host "MANQUE $($c.id) $($c.nom) : $r" -ForegroundColor Yellow
  }
}
$manquantes | Export-Csv $rapport -NoTypeInformation -Encoding UTF8
Write-Host "$ok image(s) shiny prête(s), $($manquantes.Count) manquante(s). Détail : $rapport"
