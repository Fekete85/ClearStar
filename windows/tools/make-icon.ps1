# PNG -> többméretű .ico (PNG-tömörített bejegyzésekkel, Vista+).
param([string]$Png = "src/ClearStar.App/Assets/clearstar_icon.png", [string]$Ico = "src/ClearStar.App/Assets/clearstar.ico")
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Resolve-Path $Png))
$sizes = 256, 128, 64, 48, 32, 24, 16
$entries = foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, $s, $s)
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  [PSCustomObject]@{ Size = $s; Bytes = $ms.ToArray() }
  $g.Dispose(); $bmp.Dispose()
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
  $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]$e.Bytes.Length); $w.Write([uint32]$offset)
  $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $w.Write($e.Bytes) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path (Get-Location) $Ico), $out.ToArray())
"ico: $Ico ($($out.Length) bájt, méretek: $($sizes -join ', '))"
