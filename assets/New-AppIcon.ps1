param([string]$OutDir = $PSScriptRoot, [switch]$Preview)
# App icon: navy tile (SQLSecReview family colors) with a skewed histogram, one white spike and a dashed average line.
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$navy = [Drawing.Color]::FromArgb(255, 0x12, 0x2C, 0x49)
$teal = [Drawing.Color]::FromArgb(255, 0x26, 0xC6, 0xB7)
$white = [Drawing.Color]::White

function New-RoundRect([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) { $p.AddRectangle((New-Object Drawing.RectangleF $X, $Y, $W, $H)); return $p }
    $d = 2 * $R
    $p.AddArc($X, $Y, $d, $d, 180, 90); $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90); $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function New-TopRoundBar([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $R = [Math]::Min($R, $W / 2.0)
    if ($R -le 0.5) { $p.AddRectangle((New-Object Drawing.RectangleF $X, $Y, $W, $H)); return $p }
    $d = 2 * $R
    $p.AddArc($X, $Y, $d, $d, 180, 90); $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddLine($X + $W, $Y + $H, $X, $Y + $H); $p.CloseFigure(); return $p
}

function New-IconBitmap([int]$S) {
    $bmp = New-Object Drawing.Bitmap $S, $S, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
    $small = $S -le 24
    # tile
    $m = $(if ($small) { 0.0 } else { $S * 0.03 })
    $tile = New-RoundRect $m $m ($S - 2 * $m) ($S - 2 * $m) ($S * 0.2)
    $g.FillPath((New-Object Drawing.SolidBrush $navy), $tile)
    # histogram: heights as a fraction of the plot area; index of the white spike
    if ($S -le 20) { $h = 0.45, 1.0, 0.6; $spike = 1 } elseif ($small) { $h = 0.38, 1.0, 0.62, 0.3; $spike = 1 } else { $h = 0.34, 0.52, 1.0, 0.68, 0.44, 0.26; $spike = 2 }
    $left = $S * 0.17; $right = $S * 0.83; $base = $S * 0.80; $top = $S * 0.20
    if ($small) { $left = $S * 0.14; $right = $S * 0.86; $base = $S * 0.82; $top = $S * 0.16 }
    $n = $h.Count; $gap = $(if ($small) { [Math]::Max(1.0, $S * 0.06) } else { $S * 0.035 })
    $bw = (($right - $left) - $gap * ($n - 1)) / $n
    if ($small) { $bw = [Math]::Floor($bw); $left = [Math]::Round(($S - ($bw * $n + $gap * ($n - 1))) / 2.0) }
    for ($i = 0; $i -lt $n; $i++) {
        $bh = ($base - $top) * $h[$i]; $x = $left + $i * ($bw + $gap)
        if ($small) { $x = [Math]::Round($x); $bh = [Math]::Round($bh) }
        $bar = New-TopRoundBar $x ($base - $bh) $bw $bh ($bw * 0.22)
        $c = $(if ($i -eq $spike) { $white } else { $teal })
        $g.FillPath((New-Object Drawing.SolidBrush $c), $bar)
    }
    # baseline and average line (the average line only where it stays legible)
    $lw = [Math]::Max(1.0, $S * 0.025)
    $g.FillRectangle((New-Object Drawing.SolidBrush $white), [float]($S * 0.13), [float]$base, [float]($S * 0.74), [float]$lw)
    if ($S -ge 48) {
        $avgY = [Math]::Round($base - ($base - $top) * 0.5)
        $pen = New-Object Drawing.Pen $white, ([float]([Math]::Max(2.0, $S * 0.016)))
        $pen.DashPattern = [float[]](2.0, 1.5)
        $g.DrawLine($pen, [float]($S * 0.13), [float]$avgY, [float]($S * 0.87), [float]$avgY)
    }
    $g.Dispose(); return $bmp
}

# ICO with BMP (DIB) entries below 256 px and a PNG entry at 256 px, so System.Drawing.Icon on .NET Framework loads every size.
function Get-DibBytes([Drawing.Bitmap]$B) {
    $S = $B.Width; $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
    $w.Write([int]40); $w.Write([int]$S); $w.Write([int]($S * 2)); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    for ($y = $S - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $S; $x++) { $c = $B.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
    $stride = [int]([Math]::Ceiling($S / 32.0) * 4)
    for ($y = $S - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $stride
        for ($x = 0; $x -lt $S; $x++) { if ($B.GetPixel($x, $y).A -eq 0) { $row[[int][Math]::Floor($x / 8)] = $row[[int][Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8)) } }
        $w.Write($row)
    }
    $w.Flush(); return , $ms.ToArray()
}

$null = New-Item -ItemType Directory -Force -Path $OutDir
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($s in $sizes) {
    $b = New-IconBitmap $s
    if ($s -eq 256) { $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $data = $ms.ToArray() } else { $data = Get-DibBytes $b }
    $b.Dispose(); [pscustomobject]@{ Size = $s; Data = [byte[]]$data }
}
$ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $d = $(if ($i.Size -ge 256) { 0 } else { $i.Size })
    $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]$i.Data.Length); $w.Write([int]$offset); $offset += $i.Data.Length
}
foreach ($i in $images) { $w.Write($i.Data) }
$w.Flush(); [IO.File]::WriteAllBytes((Join-Path $OutDir 'app.ico'), $ms.ToArray())

$big = New-IconBitmap 512; $big.Save((Join-Path $OutDir 'app.png'), [Drawing.Imaging.ImageFormat]::Png); $big.Dispose()

# preview sheet: every size at 1x on dark and light backgrounds, plus zooms of 16 and 32
if ($Preview) {
$sheet = New-Object Drawing.Bitmap 900, 420; $g = [Drawing.Graphics]::FromImage($sheet)
$g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(0x29, 0x2F, 0x38))), 0, 0, 900, 210)
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::White)), 0, 210, 900, 210)
foreach ($row in 0, 1) {
    $x = 12
    foreach ($s in 16, 24, 32, 48, 64, 128) { $b = New-IconBitmap $s; $g.DrawImage($b, $x, 20 + $row * 210, $s, $s); $x += $s + 16; $b.Dispose() }
    foreach ($s in 16, 32) { $b = New-IconBitmap $s; $g.DrawImage($b, $x, 20 + $row * 210, $s * 5, $s * ([Math]::Min(5, 160 / $s))); $x += [Math]::Min($s * 5, 160) + 16; $b.Dispose() }
}
$g.Dispose(); $sheet.Save((Join-Path $OutDir 'preview.png'), [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
}
$ico = New-Object Drawing.Icon (Join-Path $OutDir 'app.ico'), 32, 32
"ico ok: $($ico.Width)x$($ico.Height); bytes $((Get-Item (Join-Path $OutDir 'app.ico')).Length)"
