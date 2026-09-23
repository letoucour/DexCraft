# ============================================================
#  DexCraft — planche de contrôle des images
#  Produit outils\planche-images.html : toutes les images du dossier images,
#  avec numéro et nom de carte, pour vérifier avant de mettre en ligne.
#  Les mythiques et les transcendantes n'ont pas d'image : elles ne figurent pas sur la planche.
#
#    powershell -ExecutionPolicy Bypass -File outils\planche-images.ps1
#    puis ouvrir outils\planche-images.html dans le navigateur.
# ============================================================
param([string]$Extension = "webp")
$ErrorActionPreference = "Stop"

$racine = Split-Path -Parent $PSScriptRoot
$liste  = Get-Content (Join-Path $racine "dexcraft-images.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$cartes = $liste | Where-Object { $_.type -eq "pokemon" -or $_.type -eq "mega" }
$dossier = Join-Path $racine "images"

function Esc($s) { [Net.WebUtility]::HtmlEncode([string]$s) }

$gabarit = '<figure class="t {0}{1}" data-n="{2}" data-id="{3}"><div class="img">{4}</div><figcaption><b>{3}</b> {5}<small>{6}{7}</small></figcaption></figure>'
$tuiles = foreach ($c in $cartes) {
  $f = Join-Path $dossier "$($c.id).$Extension"
  $present = Test-Path $f
  if ($present) {
    $image = '<img loading="lazy" src="../images/{0}.{1}" alt="">' -f $c.id, $Extension
    $poidsKo = " · " + [math]::Round((Get-Item $f).Length / 1024) + " Ko"
    $classe = ""
  } else {
    $image = "<span>Pas d'image</span>"
    $poidsKo = ""
    $classe = " absent"
  }
  $etiquette = if ($c.type -eq "mega") { "Méga · base $($c.dex)" } else { "N° $($c.id)" }
  $gabarit -f $c.type, $classe, (Esc $c.nom.ToLower()), $c.id, $image, (Esc $c.nom), $etiquette, $poidsKo
}
$total   = @($cartes).Count
$absents = @($cartes | Where-Object { -not (Test-Path (Join-Path $dossier "$($_.id).$Extension")) }).Count
$poids   = [math]::Round(((Get-ChildItem $dossier -Filter "*.$Extension" -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1)

$html = @"
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Planche des images</title>
<style>
:root{--bg:#eef0fa;--surface:#fff;--ink:#1c2042;--soft:#5b6088;--line:#cfd3ea;--gold:#e0a800;--bad:#c8324b;--tile:#fbfaf6}
@media (prefers-color-scheme:dark){:root{--bg:#161a33;--surface:#20264a;--ink:#f1f0ff;--soft:#a7abd3;--line:#363e72;--gold:#ffcf3f;--bad:#ff6b81;--tile:#2a3160}}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.4 system-ui,"Segoe UI",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
h1{font-size:1.2rem;margin:0 12px 0 0}
.stat{color:var(--soft);font-weight:600}
.stat b{color:var(--ink)}.stat .bad{color:var(--bad)}
input,button{font:inherit;color:inherit;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:6px 10px}
button[aria-pressed=true]{border-color:var(--gold);box-shadow:inset 0 0 0 1px var(--gold)}
input[type=search]{flex:1 1 200px;min-width:0}
main{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--w,150px),1fr));gap:10px;padding:14px 16px 40px}
figure{margin:0;background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}
figure.mega{border-color:#2fd4c9}
figure.absent{border:2px solid var(--bad)}
.img{aspect-ratio:1;display:flex;align-items:center;justify-content:center;background:var(--tile)}
body.damier .img{background:repeating-conic-gradient(#ccc 0 25%,#fff 0 50%) 0 0/16px 16px}
.img img{width:100%;height:100%;object-fit:contain}
.img span{color:var(--bad);font-weight:700}
figcaption{padding:6px 8px;font-size:.85rem;overflow:hidden}
figcaption b{color:var(--gold)}
figcaption small{display:block;color:var(--soft)}
.hide{display:none}
</style></head><body>
<header>
  <h1>Planche des images</h1>
  <span class="stat"><b>$($total - $absents)</b> / $total images · <span class="$(if($absents){'bad'})">$absents manquante(s)</span> · $poids Mo au total</span>
  <input type="search" id="q" placeholder="Nom ou numéro">
  <button data-f="tout" aria-pressed="true">Tout</button><button data-f="pokemon">Pokémon</button><button data-f="mega">Méga</button><button data-f="absent">Manquantes</button>
  <button id="fond" aria-pressed="false">Fond en damier</button>
  <label class="stat">Taille <input type="range" id="w" min="90" max="300" value="150"></label>
</header>
<main id="g">
$($tuiles -join "`n")
</main>
<script>
let f="tout";const q=document.getElementById("q"),g=document.getElementById("g");
function maj(){const s=q.value.trim().toLowerCase();for(const t of g.children){
  const ok=(f==="tout"||t.classList.contains(f))&&(!s||t.dataset.n.includes(s)||t.dataset.id===s);t.classList.toggle("hide",!ok)}}
document.querySelectorAll("[data-f]").forEach(b=>b.onclick=()=>{f=b.dataset.f;document.querySelectorAll("[data-f]").forEach(x=>x.setAttribute("aria-pressed",x===b));maj()});
q.oninput=maj;
document.getElementById("w").oninput=e=>g.style.setProperty("--w",e.target.value+"px");
document.getElementById("fond").onclick=e=>{const on=document.body.classList.toggle("damier");e.target.setAttribute("aria-pressed",on)};
</script></body></html>
"@
$sortie = Join-Path $PSScriptRoot "planche-images.html"
[IO.File]::WriteAllText($sortie, $html, (New-Object Text.UTF8Encoding $false))
Write-Host "Planche créée : $sortie ($($total - $absents) / $total images, $absents manquante(s), $poids Mo)"
