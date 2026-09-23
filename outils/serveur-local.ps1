# ============================================================
#  DexCraft — mini-serveur local pour tester le jeu et la planche d'images
#    powershell -ExecutionPolicy Bypass -File outils\serveur-local.ps1
#  puis ouvrir http://localhost:8123/  (jeu)
#          ou http://localhost:8123/outils/planche-images.html  (planche)
#  Ctrl + C pour arrêter. Accessible uniquement depuis ce PC.
# ============================================================
param([int]$Port = 8123)
$racine = Split-Path -Parent $PSScriptRoot
$types = @{ ".html"="text/html; charset=utf-8"; ".js"="text/javascript"; ".css"="text/css"; ".json"="application/json";
            ".png"="image/png"; ".webp"="image/webp"; ".jpg"="image/jpeg"; ".svg"="image/svg+xml"; ".md"="text/plain; charset=utf-8" }
$ecoute = New-Object Net.HttpListener
$ecoute.Prefixes.Add("http://localhost:$Port/")
$ecoute.Start()
Write-Host "Serveur DexCraft : http://localhost:$Port/  (Ctrl + C pour arrêter)"
try {
  while ($ecoute.IsListening) {
    $ctx = $ecoute.GetContext()
    $rep = $ctx.Response
    try {
      $chemin = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart("/"))
      if (-not $chemin) { $chemin = "index.html" }
      $fichier = [IO.Path]::GetFullPath((Join-Path $racine $chemin))
      if ($fichier.StartsWith($racine) -and (Test-Path $fichier -PathType Leaf)) {
        $ext = [IO.Path]::GetExtension($fichier).ToLower()
        $rep.ContentType = if ($types[$ext]) { $types[$ext] } else { "application/octet-stream" }
        $rep.AddHeader("Cache-Control", "no-store")
        $flux = [IO.File]::OpenRead($fichier)
        try { $flux.CopyTo($rep.OutputStream) } finally { $flux.Dispose() }
      } else { $rep.StatusCode = 404 }
    } catch { Write-Host "Erreur sur $($ctx.Request.Url) : $($_.Exception.Message)" }
    try { $rep.Close() } catch {}
  }
} finally { $ecoute.Stop() }
