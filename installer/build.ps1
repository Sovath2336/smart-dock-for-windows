# Builds dist\SmartDock-Setup.exe using the C# compiler that ships with Windows (no extra tools needed).
#   powershell -ExecutionPolicy Bypass -File installer\build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$obj  = Join-Path $dist 'obj'
New-Item -ItemType Directory -Force $obj | Out-Null

$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe" | Select-Object -First 1 -ExpandProperty FullName
if (-not $csc) { throw 'csc.exe (.NET Framework 4) not found' }

# --- icon: dark rounded square with a 2x2 grid of colored tiles ---
Add-Type -AssemblyName System.Drawing
function New-IconPng([int]$n) {
    $bmp = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $r = [int]($n * 0.2)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 2*$r, 2*$r, 180, 90); $path.AddArc($n-2*$r-1, 0, 2*$r, 2*$r, 270, 90)
    $path.AddArc($n-2*$r-1, $n-2*$r-1, 2*$r, 2*$r, 0, 90); $path.AddArc(0, $n-2*$r-1, 2*$r, 2*$r, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 32, 32, 36))), $path)
    $cols = @('#4F8EF7', '#34C48B', '#F5A524', '#E5484D')
    $pad = [int]($n * 0.17); $gap = [int]($n * 0.07); $s = [int](($n - 2*$pad - $gap) / 2)
    for ($i = 0; $i -lt 4; $i++) {
        $x = $pad + ($i % 2) * ($s + $gap); $y = $pad + [math]::Floor($i / 2) * ($s + $gap)
        $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($cols[$i]))
        $g.FillRectangle($br, $x, $y, $s, $s)
    }
    $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    return ,$ms.ToArray()
}
$sizes = 16, 32, 48, 256
$pngs = foreach ($n in $sizes) { ,(New-IconPng $n) }
$ico = New-Object System.IO.MemoryStream; $w = New-Object System.IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $n = $sizes[$i]; $dim = if ($n -ge 256) { 0 } else { $n }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$icoPath = Join-Path $obj 'SmartDock.ico'; [System.IO.File]::WriteAllBytes($icoPath, $ico.ToArray())

# --- compile the launcher, then the installer (which embeds script + launcher) ---
$launcher = Join-Path $obj 'SmartDock.exe'
& $csc /nologo /target:winexe /optimize+ "/win32icon:$icoPath" "/out:$launcher" (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE) { throw 'launcher build failed' }

$setup = Join-Path $dist 'SmartDock-Setup.exe'
& $csc /nologo /target:winexe /optimize+ "/win32icon:$icoPath" "/out:$setup" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Management.dll `
    "/resource:$(Join-Path $root 'SmartDock.ps1'),SmartDock.ps1" "/resource:$launcher,SmartDock.exe" `
    (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE) { throw 'setup build failed' }

Write-Host "Built: $setup ($([math]::Round((Get-Item $setup).Length/1KB)) KB)"
