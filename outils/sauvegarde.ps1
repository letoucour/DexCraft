# ============================================================
#  DexCraft — sauvegarde de la base de production (Supabase), sur ce PC
#  L'offre gratuite de Supabase ne fait aucune sauvegarde : à lancer régulièrement (une fois par semaine
#  au moins, et TOUJOURS avant un script SQL important).
#
#    powershell -ExecutionPolicy Bypass -File outils\sauvegarde.ps1
#
#  La première fois, le script demande l'adresse de connexion : Supabase, bouton « Connect » en haut,
#  onglet « Connection String », type « Session pooler », copier l'adresse (elle contient [YOUR-PASSWORD] :
#  la coller telle quelle, le mot de passe est demandé à part). L'adresse est gardée dans
#  sauvegardes\adresse.txt ; le mot de passe n'est jamais enregistré.
#
#  Résultat, dans sauvegardes\ (dossier ignoré par git, à ne JAMAIS publier : il contient les e-mails
#  des joueurs) :
#    - dexcraft-jeu-<date>.dump      : tables du jeu (profils, marché, codes, historique…), structure et données ;
#    - dexcraft-comptes-<date>.dump  : comptes des joueurs (auth.users, auth.identities), données seules.
#  Les 30 sauvegardes les plus récentes de chaque sorte sont gardées.
#
#  Restauration (sur un projet Supabase neuf, en cas de catastrophe) : voir sauvegardes\LISEZMOI.txt.
# ============================================================
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
$dossier = Join-Path $racine "sauvegardes"
New-Item -ItemType Directory -Force $dossier | Out-Null

# pg_dump de PostgreSQL 17 (installé sur ce PC)
$pgDump = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\pg_dump.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $pgDump) { throw "pg_dump introuvable : PostgreSQL doit être installé dans C:\Program Files\PostgreSQL." }

# adresse de connexion (sans le mot de passe)
$fichierAdresse = Join-Path $dossier "adresse.txt"
if (Test-Path $fichierAdresse) { $adresse = (Get-Content $fichierAdresse -Raw).Trim() }
else {
  $adresse = (Read-Host "Adresse « Session pooler » copiée depuis Supabase").Trim()
  Set-Content $fichierAdresse $adresse -Encoding ASCII
}
$adresse = $adresse -replace ":\[YOUR-PASSWORD\]@", "@" -replace ":[^:@/]+@", "@"   # jamais de mot de passe dans l'adresse

$mdp = Read-Host "Mot de passe de la base de données Supabase" -AsSecureString
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($mdp))
$date = Get-Date -Format "yyyy-MM-dd_HH-mm"
try {
  $jeu = Join-Path $dossier "dexcraft-jeu-$date.dump"
  & $pgDump.FullName --dbname=$adresse --schema=public --no-owner --no-privileges --format=custom --file=$jeu
  if ($LASTEXITCODE -ne 0) { throw "La sauvegarde du jeu a échoué (adresse ou mot de passe ?)." }
  $comptes = Join-Path $dossier "dexcraft-comptes-$date.dump"
  & $pgDump.FullName --dbname=$adresse --table=auth.users --table=auth.identities --data-only --no-owner --no-privileges --format=custom --file=$comptes
  if ($LASTEXITCODE -ne 0) { throw "La sauvegarde des comptes a échoué." }
} finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }

# on garde les 30 plus récentes de chaque sorte
foreach ($sorte in "jeu", "comptes") {
  Get-ChildItem $dossier -Filter "dexcraft-$sorte-*.dump" | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item
}

$lisezmoi = Join-Path $dossier "LISEZMOI.txt"
if (-not (Test-Path $lisezmoi)) {
  Set-Content $lisezmoi -Encoding UTF8 @"
Sauvegardes DexCraft : NE JAMAIS PUBLIER NI ENVOYER (e-mails des joueurs, mots de passe chiffrés).

Restaurer, en cas de perte de la base (projet Supabase neuf) :
1. Dans le nouveau projet : lancer dexcraft-supabase.sql puis dexcraft-config.sql (éditeur SQL).
2. Comptes d'abord (les profils y font référence), puis le jeu, depuis ce PC (adresse « Session pooler » du NOUVEAU projet) :
   pg_restore --dbname=<adresse> --data-only --disable-triggers dexcraft-comptes-<date>.dump
   pg_restore --dbname=<adresse> --no-owner --no-privileges --clean --if-exists dexcraft-jeu-<date>.dump
3. Relancer dexcraft-serveur.sql, dexcraft-serveur-2.sql, dexcraft-serveur-3.sql (droits et fonctions).
4. Mettre la nouvelle adresse et la nouvelle clé du projet dans index.html (SUPABASE_URL, SUPABASE_ANON_KEY).
En cas de doute, demander de l'aide avant de restaurer : une restauration ratée peut effacer des données.
"@
}
Write-Host ""
Write-Host "Sauvegarde terminée :" -ForegroundColor Green
Get-ChildItem $dossier -Filter "dexcraft-*-$date.dump" | ForEach-Object { Write-Host ("  {0}  ({1:N0} Ko)" -f $_.Name, ($_.Length / 1KB)) }
