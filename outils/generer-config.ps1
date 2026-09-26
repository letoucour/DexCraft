# ============================================================
#  DexCraft — génère dexcraft-config.sql depuis index.html
#  Le serveur (fonctions SQL) a besoin des données du jeu : raretés, probabilités,
#  évolutions, boutique, VoltoBataille… Elles sont lues dans index.html par Edge
#  (sans fenêtre), puis écrites dans la table game_config.
#
#    powershell -ExecutionPolicy Bypass -File outils\generer-config.ps1
#  puis coller dexcraft-config.sql dans Supabase > SQL Editor > Run.
#  À refaire après tout changement de cartes, de raretés ou de règles.
#
#  Cartes secrètes (0.8.7) : leurs données sont dans secret\cartes-secretes.json, sur ce PC seulement
#  (dossier ignoré par git : le dépôt est public). Le script les injecte dans une copie temporaire de la page
#  pour l'export, et écrit aussi secret\cartes-secretes.sql : à lancer dans Supabase quand une carte
#  secrète est ajoutée ou modifiée. Ne jamais publier ces deux fichiers.
# ============================================================
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
$edge = @("C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe","C:\Program Files\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge introuvable." }
$utf8 = New-Object Text.UTF8Encoding $false

# cartes secrètes : fichier local obligatoire (sans lui, le serveur perdrait les mythiques et transcendantes)
$fSecret = Join-Path $racine "secret\cartes-secretes.json"
if (-not (Test-Path $fSecret)) { throw "secret\cartes-secretes.json introuvable : les cartes secrètes ne sont que sur le PC de Theo." }
$secret = [IO.File]::ReadAllText($fSecret, $utf8)
$cartes = $secret | ConvertFrom-Json   # vérifie que le JSON est valide

# copie temporaire de la page, avec les cartes secrètes, dans le même dossier (chemins relatifs identiques)
$tmp = Join-Path $racine "index-export.tmp.html"
$html = [IO.File]::ReadAllText((Join-Path $racine "index.html"), $utf8)
$html = $html.Replace("<head>", "<head><script>window.DC_SECRETS=$secret;</script>")
[IO.File]::WriteAllText($tmp, $html, $utf8)
try {
  $page = "file:///" + ($tmp -replace "\\","/") + "?export-config"
  $profil = Join-Path $env:TEMP "dexcraft-export-edge"
  $dom = & $edge --headless=new --disable-gpu --no-first-run --user-data-dir="$profil" --virtual-time-budget=3000 --dump-dom $page 2>$null | Out-String
} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
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
[IO.File]::WriteAllText((Join-Path $racine "dexcraft-config.sql"), $sql, $utf8)
Write-Host "dexcraft-config.sql écrit ($($json.Length) caractères)."

# données des cartes secrètes pour le serveur (table secret_cards, créée par dexcraft-serveur-3.sql)
# une carte par ligne dans le fichier : « "2001": [ ... ], » (texte repris tel quel, PowerShell 5 déforme les tableaux imbriqués)
$ids = @(); $lignes = @()
foreach ($l in ($secret -split "`n")) {
  $mm = [regex]::Match($l, '^\s*"(\d+)"\s*:\s*(\[.*\])\s*,?\s*$')
  if (-not $mm.Success) { continue }
  $d = $mm.Groups[2].Value; $null = $d | ConvertFrom-Json
  $ids += [int]$mm.Groups[1].Value
  $lignes += "  ($($mm.Groups[1].Value), `$sc`$$d`$sc`$::jsonb)"
}
if ($ids.Count -ne @($cartes.PSObject.Properties).Count) { throw "Fichier des cartes secretes : une carte par ligne, au format  ""2001"": [ ... ],  (voir les lignes existantes)." }
$sqlS = @"
-- ============================================================
--  DexCraft — CARTES SECRÈTES (générées par outils\generer-config.ps1). NE JAMAIS PUBLIER CE FICHIER.
--  À lancer dans Supabase > SQL Editor après dexcraft-serveur-3.sql, et après tout ajout ou changement de carte secrète.
-- ============================================================
insert into public.secret_cards (id, data) values
$($lignes -join ",`n")
on conflict (id) do update set data = excluded.data;
delete from public.secret_cards where id not in ($($ids -join ", "));
select 'cartes secrètes OK' as verif, count(*) as cartes from public.secret_cards;
"@
[IO.File]::WriteAllText((Join-Path $racine "secret\cartes-secretes.sql"), $sqlS, $utf8)
Write-Host "secret\cartes-secretes.sql écrit ($($ids.Count) cartes secrètes)."
