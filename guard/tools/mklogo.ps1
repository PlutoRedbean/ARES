Add-Type -AssemblyName System.Drawing

$W = 1280; $H = 360
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'ClearTypeGridFit'
$bg = [System.Drawing.Color]::FromArgb(10,14,20)
$g.Clear($bg)

$grid = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(16,22,30)), 1
for ($x = 0; $x -lt $W; $x += 40) { $g.DrawLine($grid, $x, 0, $x, $H) }
for ($y = 0; $y -lt $H; $y += 40) { $g.DrawLine($grid, 0, $y, $W, $y) }

$acc = New-Object System.Drawing.Color
$acc = [System.Drawing.Color]::FromArgb(55,208,160)
$fg  = [System.Drawing.Color]::FromArgb(230,237,243)
$dim = [System.Drawing.Color]::FromArgb(120,140,155)

$cx = 150; $cy = 180; $s = 92
$pts = @(
  (New-Object System.Drawing.PointF($cx, ($cy - $s))),
  (New-Object System.Drawing.PointF(($cx + $s*0.82), ($cy - $s*0.62))),
  (New-Object System.Drawing.PointF(($cx + $s*0.82), ($cy + $s*0.15))),
  (New-Object System.Drawing.PointF($cx, ($cy + $s))),
  (New-Object System.Drawing.PointF(($cx - $s*0.82), ($cy + $s*0.15))),
  (New-Object System.Drawing.PointF(($cx - $s*0.82), ($cy - $s*0.62)))
)
$penShield = New-Object System.Drawing.Pen $acc, 6
$penShield.LineJoin = 'Round'
$g.DrawPolygon($penShield, [System.Drawing.PointF[]]$pts)

$pen = New-Object System.Drawing.Pen $acc, 5
$pen.StartCap = 'Round'; $pen.EndCap = 'Round'
$g.DrawLine($pen, ($cx-34), ($cy-8), $cx, ($cy-30))
$g.DrawLine($pen, $cx, ($cy-30), ($cx+34), ($cy-8))
$g.DrawLine($pen, ($cx-34), ($cy+8), $cx, ($cy+30))
$g.DrawLine($pen, $cx, ($cy+30), ($cx+34), ($cy+8))
$g.DrawEllipse($pen, ($cx-9), ($cy-9), 18, 18)

$fWord = New-Object System.Drawing.Font("Consolas", 60, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fSub  = New-Object System.Drawing.Font("Consolas", 27, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fTag  = New-Object System.Drawing.Font("Consolas", 21, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$bWord = New-Object System.Drawing.SolidBrush $fg
$bSub  = New-Object System.Drawing.SolidBrush $acc
$bTag  = New-Object System.Drawing.SolidBrush $dim
$g.DrawString("ARES GUARD", $fWord, $bWord, 278, 84)
$g.DrawString("PII redaction, on the wire", $fSub, $bSub, 282, 196)
$g.DrawString("UART in  ->  L1 rules  ->  masked text + audit", $fTag, $bTag, 284, 240)

$g.Dispose()
$bmp.Save("docs\ares-guard-logo.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"saved: " + (Get-Item docs\ares-guard-logo.png).Length + " bytes"
