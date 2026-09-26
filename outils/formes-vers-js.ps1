# ============================================================
#  DexCraft — convertit outils\formes.json en données pour index.html (objet FORMS)
#  Formes régionales : numéros 5001 et suivants ; Gigamax : 6001 et suivants.
#  La rareté des formes régionales est celle du Pokémon d'origine (remplie dans index.html) ;
#  les Gigamax ont la rareté des méga-évolutions (4).
#
#    powershell -ExecutionPolicy Bypass -File outils\formes-vers-js.ps1
# ============================================================
$ErrorActionPreference = "Stop"
$j = Get-Content (Join-Path $PSScriptRoot "formes.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$GEN = @{ alola = 7; galar = 8; hisui = 8; paldea = 9; gmax = 8 }
$nReg = 5000; $nGmax = 6000; $lignes = @(); $ids = @{}
foreach ($f in $j) {
  if ($f.genre -eq "gmax") { $nGmax++; $id = $nGmax; $rar = 4; $poids = 0 } else { $nReg++; $id = $nReg; $rar = "null"; $poids = $f.poids }
  $ids[$f.nom] = $id
  $nom = $f.nomFr -replace '"', '\"'
  $cat = $f.categorie -replace '"', '\"'
  $lignes += "  ${id}:[""$nom"",""$cat"",$($GEN[$f.genre]),[$($f.types -join ',')],$($f.taille),$poids,[$($f.stats -join ',')],$rar,{base:$($f.base),kind:""$($f.genre)""}]"
}
$sortie = "const FORMS={`n" + ($lignes -join ",`n") + "`n};"
Set-Content (Join-Path $PSScriptRoot "formes.js.txt") $sortie -Encoding UTF8
# correspondance nom PokeAPI -> numéro de carte (pour les évolutions et les images)
$ids.GetEnumerator() | Sort-Object Value | ForEach-Object { [pscustomobject]@{ nom = $_.Key; id = $_.Value } } | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot "formes-ids.json") -Encoding UTF8
Write-Host "outils\formes.js.txt écrit ($($lignes.Count) cartes)."
