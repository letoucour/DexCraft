# ============================================================
#  DexCraft — génère dexcraft-config.sql depuis index.html
#  Le serveur (fonctions SQL) a besoin des données du jeu : raretés, probabilités,
#  évolutions, boutique, VoltoBataille… Elles sont lues dans index.html par Edge
#  (sans fenêtre), puis écrites dans la table game_config.
#
#    powershell -ExecutionPolicy Bypass -File outils\generer-config.ps1
#  puis coller dexcraft-config.sql dans Supabase > SQL Editor > Run.
#  À refaire après tout changement de cartes, de raretés ou de règles.
# ============================================================
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
$edge = @("C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe","C:\Program Files\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge introuvable." }
$page = "file:///" + ((Join-Path $racine "index.html") -replace "\\","/") + "?export-config"
$profil = Join-Path $env:TEMP "dexcraft-export-edge"
$dom = & $edge --headless=new --disable-gpu --no-first-run --user-data-dir="$profil" --virtual-time-budget=3000 --dump-dom $page 2>$null | Out-String
$m = [regex]::Match($dom, '<pre id="export-config">(.*?)</pre>', "Singleline")
if (-not $m.Success) { throw "Configuration introuvable dans la page. Vérifiez index.html." }
$json = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$null = $json | ConvertFrom-Json   # vérifie que le JSON est valide
$sql = @"
-- ============================================================
--  DexCraft — configuration du jeu pour le serveur (générée par outils\generer-config.ps1)
--  Ne pas modifier à la main : relancer le script après un changement dans index.html.
-- ============================================================
create table if not exists public.game_config (id int primary key, data jsonb not null);
alter table public.game_config enable row level security;
insert into public.game_config (id, data) values (1, `$cfg`$$json`$cfg`$::jsonb)
on conflict (id) do update set data = excluded.data;
select 'configuration OK' as verif, jsonb_array_length(data->'dexOrder') as cartes from public.game_config where id = 1;
"@
[IO.File]::WriteAllText((Join-Path $racine "dexcraft-config.sql"), $sql, (New-Object Text.UTF8Encoding $false))
Write-Host "dexcraft-config.sql écrit ($($json.Length) caractères)."
