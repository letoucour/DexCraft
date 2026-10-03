# ============================================================
#  DexCraft : clés des notifications (1.10.0). À lancer UNE fois sur le PC de Theo :
#    powershell -ExecutionPolicy Bypass -File C:\DexCraft\outils\cles-notifications.ps1
#  Crée la paire de clés VAPID (P-256) et le secret d'appel de la fonction dc-push, les range dans
#  secret\notifications.txt (jamais publié), écrit la clé publique dans index.html (PUSH_KEY) et affiche ce qu'il faut
#  coller dans Supabase. Relancé : réutilise les clés déjà créées (en changer désabonnerait tous les appareils).
#  -Nouvelles : force de nouvelles clés. -Essai : crée des clés de test et les affiche, sans rien écrire.
# ============================================================
param([switch]$Nouvelles, [switch]$Essai)
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
$fichier = Join-Path $racine "secret\notifications.txt"
$index = Join-Path $racine "index.html"

function B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

if (-not $Essai -and -not $Nouvelles -and (Test-Path $fichier)) {
  $v = @{}; Get-Content $fichier -Encoding UTF8 | ForEach-Object { if ($_ -match '^(\w+)=(.+)$') { $v[$matches[1]] = $matches[2] } }
  $pub = $v.VAPID_PUBLIC_KEY; $priv = $v.VAPID_PRIVATE_KEY; $sec = $v.PUSH_SECRET
  Write-Host "Clés déjà créées : reprises de secret\notifications.txt." -ForegroundColor Yellow
} else {
  $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
  $p = $ec.ExportParameters($true)
  $pub = B64Url ([byte[]](@(4) + $p.Q.X + $p.Q.Y))
  $priv = B64Url $p.D
  $rnd = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
  $sec = B64Url $rnd
  if ($Essai) { Write-Host "Essai : clé publique $pub ($($pub.Length) caractères), privée de $($priv.Length) caractères, secret de $($sec.Length)."; exit 0 }
  New-Item -ItemType Directory -Force (Split-Path $fichier) | Out-Null
  @("# Notifications DexCraft (1.10.0) : NE JAMAIS PUBLIER.", "VAPID_PUBLIC_KEY=$pub", "VAPID_PRIVATE_KEY=$priv", "PUSH_SECRET=$sec") |
    Set-Content -Path $fichier -Encoding UTF8
  Write-Host "Clés créées et rangées dans secret\notifications.txt." -ForegroundColor Green
}

# clé publique dans index.html
$utf8 = New-Object System.Text.UTF8Encoding($false)
$html = [System.IO.File]::ReadAllText($index, $utf8)
$neuf = [regex]::Replace($html, 'const PUSH_KEY="[^"]*";', "const PUSH_KEY=""$pub"";")
if ($neuf -ne $html) { [System.IO.File]::WriteAllText($index, $neuf, $utf8); Write-Host "Clé publique écrite dans index.html (PUSH_KEY)." -ForegroundColor Green }
else { Write-Host "index.html avait déjà cette clé publique." }

Write-Host ""
Write-Host "1) Supabase, Edge Functions, Secrets : ajouter ces trois secrets" -ForegroundColor Cyan
Write-Host "   VAPID_PUBLIC_KEY   $pub"
Write-Host "   VAPID_PRIVATE_KEY  $priv"
Write-Host "   PUSH_SECRET        $sec"
Write-Host "2) Supabase, SQL Editor : lancer cette ligne (le même secret, pour la tâche pg_cron)" -ForegroundColor Cyan
Write-Host "   select vault.create_secret('$sec', 'dc_push_secret');"
Write-Host "3) Supabase, Edge Functions : créer la fonction dc-push avec le code de supabase\functions\dc-push\index.ts," -ForegroundColor Cyan
Write-Host "   « Verify JWT » désactivé."
