<#
RUN: .\convert.ps1 -Height 2160 -File foo
Reads foo.png from this folder, scales to 720p, outputs t_foo.png, appends threshold to thresholds.yaml.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Height,
    [Parameter(Mandatory)][string]$File,
    [double]$Threshold = 0.80
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$VALID_HEIGHTS = @(720, 900, 1080, 1440, 2160)

if ($Height -notin $VALID_HEIGHTS) {
    Write-Error "Invalid height $Height. Valid: $($VALID_HEIGHTS -join ', ')"
    exit 1
}

$srcPath = Join-Path $PSScriptRoot "$File.png"
if (-not (Test-Path $srcPath)) {
    Write-Error "File not found: $srcPath"
    exit 1
}

$scale = 720.0 / $Height

Write-Host "Loading $File.png (source height=$Height, scale=$([Math]::Round($scale, 4)))"

$srcBmp = [System.Drawing.Bitmap]::new($srcPath)
$srcW = $srcBmp.Width
$srcH = $srcBmp.Height
Write-Host "Source image: ${srcW}x${srcH}"

if ([Math]::Abs($scale - 1.0) -lt 0.001) {
    $scaledBmp = $srcBmp
}
else {
    $newW = [Math]::Max(1, [int][Math]::Round($srcW * $scale))
    $newH = [Math]::Max(1, [int][Math]::Round($srcH * $scale))
    Write-Host "Scaling to ${newW}x${newH}"
    $scaledBmp = [System.Drawing.Bitmap]::new($newW, $newH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($scaledBmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($srcBmp, 0, 0, $newW, $newH)
    $g.Dispose()
    $srcBmp.Dispose()
}

$outPath = Join-Path $PSScriptRoot "t_$File.png"
$scaledBmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$scaledBmp.Dispose()
Write-Host "Saved: t_$File.png ($([Math]::Round((Get-Item $outPath).Length / 1024, 1)) KB)"

# Append threshold to thresholds.yaml
$yamlPath = Join-Path $PSScriptRoot 'thresholds.yaml'
if (Test-Path $yamlPath) {
    $content = Get-Content $yamlPath -Raw
}
else {
    $content = ''
}
$entry = "$File`: $($Threshold.ToString('F2'))"

if ($content -match "(?m)^$File`:") {
    Write-Host "Threshold for '$File' already exists in thresholds.yaml, skipping"
}
else {
    $trimmed = $content.TrimEnd()
    Set-Content -Path $yamlPath -Value "$trimmed`n$entry`n" -NoNewline
    Write-Host "Added '$entry' to thresholds.yaml"
}
