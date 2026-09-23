# ============================================================
#  DexCraft — téléchargement des illustrations des cartes
#  Source : dépôt PokeAPI/sprites (illustrations officielles) et API PokeAPI.
#  Lit dexcraft-images.json et range chaque image sous images\<fichier>.
#
#  Exemples (depuis le dossier du dépôt) :
#    powershell -ExecutionPolicy Bypass -File outils\telecharger-images.ps1 -Essai -Seulement 1,6,4002,4046
#    powershell -ExecutionPolicy Bypass -File outils\telecharger-images.ps1
#
#  -Essai      : affiche seulement les adresses trouvées, sans rien télécharger.
#  -Seulement  : limite à quelques numéros de carte.
#  Relançable : les images déjà présentes sont sautées.
# ============================================================
param(
  [switch]$Essai,
  [string]$Seulement = "",
  [int]$Pause = 150
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$racine  = Split-Path -Parent $PSScriptRoot
$liste   = Get-Content (Join-Path $racine "dexcraft-images.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$dossier = Join-Path $racine "images"
$rapport = Join-Path $PSScriptRoot "images-manquantes.csv"
$ART     = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork"
if (-not $Essai) { New-Item -ItemType Directory -Force $dossier | Out-Null }

# Adresse de l'illustration d'une carte, ou exception si introuvable
function Trouver-Adresse($c) {
  if ($c.type -eq "pokemon") { return "$ART/$($c.dex).png" }
  if ($c.type -eq "mega") {
    $espece = Invoke-RestMethod "https://pokeapi.co/api/v2/pokemon-species/$($c.dex)"
    $megas  = @($espece.varieties | ForEach-Object { $_.pokemon.name } | Where-Object { $_ -match "-mega" })
    $fin    = if ($c.forme) { "-mega-" + $c.forme.ToLower() } else { "-mega" }
    $nom    = $megas | Where-Object { $_.EndsWith($fin) } | Select-Object -First 1
    if (-not $nom) { throw "variante méga absente de PokeAPI (trouvées : $($megas -join ', '))" }
    $fiche  = Invoke-RestMethod "https://pokeapi.co/api/v2/pokemon/$nom"
    $url    = $fiche.sprites.other.'official-artwork'.front_default
    if (-not $url) { throw "$nom existe dans PokeAPI mais sans illustration" }
    return $url
  }
  throw "carte spéciale ($($c.type)) : image à fournir à la main"
}

$filtre = @($Seulement -split "[,; ]+" | Where-Object { $_ } | ForEach-Object { [int]$_ })
$manquantes = @()
$ok = 0
foreach ($c in $liste) {
  if ($filtre.Count -and -not ($filtre -contains [int]$c.id)) { continue }
  $dest = Join-Path $dossier $c.fichier
  if (-not $Essai -and (Test-Path $dest)) { continue }
  try {
    $url = Trouver-Adresse $c
    if ($Essai) { Write-Host "ESSAI  $($c.fichier)  $($c.nom)  ->  $url" }
    else {
      Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
      Write-Host "OK     $($c.fichier)  $($c.nom)"
    }
    $ok++
    Start-Sleep -Milliseconds $Pause
  } catch {
    $manquantes += [pscustomobject]@{ id = $c.id; nom = $c.nom; fichier = $c.fichier; raison = $_.Exception.Message }
    Write-Host "MANQUE $($c.fichier)  $($c.nom) : $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

$manquantes | Export-Csv $rapport -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "$ok image(s) trouvée(s), $($manquantes.Count) manquante(s). Détail : $rapport"
