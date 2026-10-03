# ============================================================
#  DexCraft — passe les scripts SQL sur la base de production (Supabase), en une seule commande (1.6.3)
#  Remplace le copier-coller un par un dans l'éditeur SQL de Supabase.
#
#    powershell -ExecutionPolicy Bypass -File outils\passer-sql.ps1
#
#  - Seuls les fichiers modifiés depuis le dernier passage sont lancés, dans l'ordre de CLAUDE.md :
#    configuration (les trois parties ensemble dès que l'une change, voir l'incident de la 1.3.7), serveur
#    parties 1, 2, 3… (toutes celles qui existent), cartes secrètes, puis les nouvelles migrations (migrations\migration-*.sql jamais passées).
#  - Chaque fichier est passé d'un bloc (une transaction) : en cas d'erreur, rien de ce fichier n'est appliqué,
#    et le script s'arrête là ; relancer ensuite reprend au fichier en erreur.
#  - Le mot de passe est demandé une fois, jamais enregistré. L'adresse de connexion est celle de
#    outils\sauvegarde.ps1 (sauvegardes\adresse.txt), demandée la première fois si besoin.
#  - Mémoire des fichiers passés : sauvegardes\sql-passes.txt (dossier ignoré par git). Au tout premier
#    lancement, rien n'est passé : l'état actuel est noté comme déjà à jour (tout a été passé à la main avant).
#  - Options : -Voir (affiche ce qui serait passé, sans rien lancer) ; -Tout (repasse configuration, serveur et
#    cartes secrètes, jamais les migrations) ; -Fichier chemin (passe ce fichier-là seulement).
# ============================================================
param([switch]$Voir, [switch]$Tout, [string]$Fichier, [string]$Adresse)
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
$dossier = Join-Path $racine "sauvegardes"
New-Item -ItemType Directory -Force $dossier | Out-Null
$etat = Join-Path $dossier "sql-passes.txt"

$psql = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $psql) { throw "psql introuvable : PostgreSQL doit être installé dans C:\Program Files\PostgreSQL." }

# fichiers dans l'ordre de passage
$config = @("dexcraft-config.sql", "dexcraft-config-2.sql", "dexcraft-config-3.sql")
$serveur = @("dexcraft-serveur.sql") + (2..20 | ForEach-Object { "dexcraft-serveur-$_.sql" } | Where-Object { Test-Path (Join-Path $racine $_) })   # parties 1, 2, 3… dans l'ordre
$secret = @("secret\cartes-secretes.sql")
$migrations = Get-ChildItem (Join-Path $racine "migrations") -Filter "migration-*.sql" | ForEach-Object { "migrations\" + $_.Name } |
  Sort-Object { [version](($_ -replace '^migrations\\migration-', '' -replace '\.sql$', '') -replace '[^0-9.]', '') }

function Empreinte($f) { (Get-FileHash (Join-Path $racine $f) -Algorithm SHA256).Hash }
$passes = @{}
if (Test-Path $etat) { Get-Content $etat | ForEach-Object { $p = $_ -split "`t"; if ($p.Count -eq 2) { $passes[$p[0]] = $p[1] } } }
function Noter($f) { $passes[$f] = Empreinte $f; $passes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)`t$($_.Value)" } | Set-Content $etat -Encoding UTF8 }

$tous = $config + $serveur + $secret + $migrations | Where-Object { Test-Path (Join-Path $racine $_) }
if (-not (Test-Path $etat) -and -not $Fichier) {
  foreach ($f in $tous) { Noter $f }
  Write-Host "Premier lancement : $($tous.Count) fichiers notés comme déjà passés (état actuel de la base). Rien n'a été lancé." -ForegroundColor Yellow
  Write-Host "Les prochaines fois, seuls les fichiers modifiés seront passés."
  exit 0
}

# liste à passer
if ($Fichier) { $liste = @($Fichier) }
else {
  $change = { param($f) -not $passes.ContainsKey($f) -or $passes[$f] -ne (Empreinte $f) }
  $liste = @()
  if ($Tout -or ($config | Where-Object { & $change $_ })) { $liste += $config }
  $liste += $serveur + $secret | Where-Object { (Test-Path (Join-Path $racine $_)) -and ($Tout -or (& $change $_)) }
  $liste += $migrations | Where-Object { -not $passes.ContainsKey($_) }   # une migration ne passe qu'une fois, même modifiée ensuite
}
if (-not $liste.Count) { Write-Host "Rien à passer : la base est à jour." -ForegroundColor Green; exit 0 }
Write-Host "À passer, dans l'ordre :" -ForegroundColor Cyan
$liste | ForEach-Object { Write-Host "  - $_" }
if ($Voir) { exit 0 }

# connexion
if (-not $Adresse) {
  $fichierAdresse = Join-Path $dossier "adresse.txt"
  if (Test-Path $fichierAdresse) { $Adresse = (Get-Content $fichierAdresse -Raw).Trim() }
  else {
    $Adresse = (Read-Host "Adresse « Session pooler » copiée depuis Supabase (bouton Connect)").Trim()
    Set-Content $fichierAdresse $Adresse -Encoding ASCII
  }
}
$Adresse = $Adresse -replace ":\[YOUR-PASSWORD\]@", "@" -replace ":[^:@/]+@", "@"   # jamais de mot de passe dans l'adresse
if (-not $env:PGPASSWORD) {
  $mdp = Read-Host "Mot de passe de la base de données Supabase" -AsSecureString
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($mdp))
}
$env:PGCLIENTENCODING = "UTF8"
try {
  foreach ($f in $liste) {
    Write-Host ""
    Write-Host "== $f" -ForegroundColor Cyan
    $niveau = if ($f -like "migrations*") { "notice" } else { "warning" }   # les migrations affichent leur bilan (raise notice)
    & $psql.FullName $Adresse -X -q -1 -v ON_ERROR_STOP=1 -P footer=off -c "set client_min_messages = $niveau" -f (Join-Path $racine $f)
    if ($LASTEXITCODE -ne 0) { Write-Host "ERREUR dans $f : rien de ce fichier n'a été appliqué. Arrêt (relancer reprendra ici)." -ForegroundColor Red; exit 1 }
    Noter $f
  }
} finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "Terminé : $($liste.Count) fichier(s) passé(s)." -ForegroundColor Green
