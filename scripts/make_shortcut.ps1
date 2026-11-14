# make_shortcut.ps1 - draws the labcheck icon and puts a "Lab Check" shortcut on the Desktop.
# Run again any time (e.g. after moving the repo):  powershell -ExecutionPolicy Bypass -File scripts\make_shortcut.ps1

# Optional: -StatusFile "<path to a .md file>" makes the dashboard also write its results there.
param([string]$StatusFile = '')

$extra = ''
if ($StatusFile) { $extra = " --status-file `"$StatusFile`"" }
$repo    = Split-Path -Parent $PSScriptRoot
$script  = Join-Path $repo 'scripts\labcheck.py'
$iconDir = Join-Path $repo 'assets'
$icon    = Join-Path $iconDir 'labcheck.ico'
$python  = (Get-Command python).Source
$wt      = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source

# 1. Draw a 64x64 icon: dark tile, 4 nodes (control plane on top, 2 workers, obs) joined by lines
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
$bmp = New-Object System.Drawing.Bitmap 64, 64
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::Transparent)
$g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 22, 27, 34))), 2, 2, 60, 60)
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 88, 166, 255)), 3
$cp = @(32, 16); $nodes = @(@(14, 46), @(32, 46), @(50, 46))
foreach ($n in $nodes) { $g.DrawLine($pen, $cp[0], $cp[1], $n[0], $n[1]) }
$green = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 63, 185, 80))
$blue  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 88, 166, 255))
$g.FillEllipse($blue, $cp[0] - 8, $cp[1] - 8, 16, 16)
foreach ($n in $nodes) { $g.FillEllipse($green, $n[0] - 6, $n[1] - 6, 12, 12) }
$g.Dispose()

# Save as .ico: a 6-byte header + one 16-byte directory entry + the image stored as PNG
$png = New-Object System.IO.MemoryStream
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$bytes = $png.ToArray()
$fs = [System.IO.File]::Create($icon)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]1)          # reserved, type=icon, 1 image
$w.Write([byte]64); $w.Write([byte]64); $w.Write([byte]0); $w.Write([byte]0)  # 64x64, no palette
$w.Write([UInt16]1); $w.Write([UInt16]32)                              # colour planes, 32-bit colour
$w.Write([UInt32]$bytes.Length); $w.Write([UInt32]22)                  # image size, offset to image
$w.Write($bytes); $w.Close()

# 2. Create the shortcut. Prefer Windows Terminal (colours + title); fall back to plain python.
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lab Check.lnk'
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
if ($wt) {
    $lnk.TargetPath = $wt
    $lnk.Arguments  = "--title `"k8s lab check`" --suppressApplicationTitle `"$python`" `"$script`" --watch 5$extra"
} else {
    $lnk.TargetPath = $python
    $lnk.Arguments  = "`"$script`" --watch 5$extra"
}
$lnk.WorkingDirectory = $repo
$lnk.IconLocation     = "$icon,0"
$lnk.Description      = 'Live connectivity check for the k8s security lab VMs'
$lnk.Save()
Write-Host "Shortcut created: $lnkPath"
Write-Host "Icon: $icon"
