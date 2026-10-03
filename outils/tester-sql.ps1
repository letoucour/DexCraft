# ============================================================
#  DexCraft : tests du serveur sur une base PostgreSQL locale neuve (1.10.0). Rien ne touche la vraie base.
#    powershell -ExecutionPolicy Bypass -File C:\DexCraft\outils\tester-sql.ps1
#  Crée au besoin un petit serveur PostgreSQL de test (dossier temporaire, port 5498, sans mot de passe), y recrée la base
#  dexcraft_test, passe tous les scripts dans l'ordre (tables, configuration, serveur, cartes secrètes), puis les tests de
#  tests\ (smoke.sql, puis test-*.sql). Chaque ligne de test commence par OK ou ERR ; une erreur non « attendue » fait échouer.
#  -Garder : laisse le serveur de test allumé à la fin (psql -p 5498 -U postgres -d dexcraft_test).
# ============================================================
param([int]$Port = 5498, [string]$Dossier = (Join-Path $env:TEMP "dexcraft-tests-pg"), [switch]$Garder)
$ErrorActionPreference = "Continue"   # psql écrit ses messages sur la sortie d'erreur : on lit $LASTEXITCODE à la place
$racine = Split-Path -Parent $PSScriptRoot
$bin = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $bin) { throw "PostgreSQL introuvable (C:\Program Files\PostgreSQL)." }
$bin = Split-Path $bin.FullName
$env:PGCLIENTENCODING = "UTF8"
$psql = Join-Path $bin "psql.exe"

# serveur de test : créé une fois, démarré sans hériter de la console (sinon la commande ne rend jamais la main)
if (-not (Test-Path (Join-Path $Dossier "PG_VERSION"))) {
  & (Join-Path $bin "initdb.exe") -D $Dossier -U postgres -E UTF8 --locale=C -A trust | Out-Null
}
& $psql -p $Port -U postgres -d postgres -tAc "select 1" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  $p = Start-Process -FilePath (Join-Path $bin "pg_ctl.exe") -ArgumentList @("-D", "`"$Dossier`"", "-o", "`"-p $Port`"", "-l", "`"$Dossier\journal.txt`"", "start") `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Dossier\pg_ctl-sortie.txt" -RedirectStandardError "$Dossier\pg_ctl-erreurs.txt"
  $p.WaitForExit()
  for ($i = 0; $i -lt 30; $i++) { & $psql -p $Port -U postgres -d postgres -tAc "select 1" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 1 }
}
& $psql -p $Port -U postgres -d postgres -q -c "drop database if exists dexcraft_test" -c "create database dexcraft_test" 2>$null | Out-Null

$fichiers = @("tests\shim.sql", "dexcraft-supabase.sql", "dexcraft-config.sql", "dexcraft-config-2.sql", "dexcraft-config-3.sql", "dexcraft-serveur.sql")
$fichiers += 2..20 | ForEach-Object { "dexcraft-serveur-$_.sql" } | Where-Object { Test-Path (Join-Path $racine $_) }
if (Test-Path (Join-Path $racine "secret\cartes-secretes.sql")) { $fichiers += "secret\cartes-secretes.sql" }
foreach ($f in $fichiers) {
  $out = & $psql -p $Port -U postgres -d dexcraft_test -v ON_ERROR_STOP=1 -q -f (Join-Path $racine $f) 2>&1
  if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 5 | Write-Host; throw "Échec en passant $f." }
}
Write-Host "Base de test prête ($($fichiers.Count) fichiers)." -ForegroundColor Green

$ok = 0; $ko = @()
$tests = @("tests\smoke.sql") + (Get-ChildItem (Join-Path $racine "tests\test-*.sql") | Sort-Object Name | ForEach-Object { "tests\$($_.Name)" })
foreach ($t in $tests) {
  $lignes = & $psql -p $Port -U postgres -d dexcraft_test -f (Join-Path $racine $t) 2>&1 | ForEach-Object { "$_" }
  foreach ($l in $lignes) {
    $x = ($l -replace '^.*NOTICE:\s+', '').Trim()
    if ($x -match '^OK ') { $ok++ }
    elseif ($x -match '^ERR ' -and $x -notmatch 'attendu') { $ko += "$t : $x" }
    elseif ($x -match 'ERROR:|ERREUR' ) { $ko += "$t : $x" }
  }
}
if (-not $Garder) { & (Join-Path $bin "pg_ctl.exe") -D $Dossier stop -m fast 2>&1 | Out-Null }
Write-Host "$ok vérifications réussies." -ForegroundColor Green
if ($ko.Count) { Write-Host "$($ko.Count) échec(s) :" -ForegroundColor Red; $ko | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; exit 1 }
Write-Host "Tout est bon." -ForegroundColor Green
