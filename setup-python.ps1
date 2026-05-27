<#
RUN: .\setup.ps1
Finds Python 3, installs if needed, then installs pip dependencies.
#>

$ErrorActionPreference = 'Stop'

# Find Python 3 in the standard install location
$pyPath = $null
$pyBase = "$env:LOCALAPPDATA\Programs\Python"
if (Test-Path $pyBase) {
    $found = Get-ChildItem $pyBase -Directory |
    Where-Object { $_.Name -match '^Python3' } |
    Sort-Object Name -Descending |
    Select-Object -First 1

    if ($found) {
        $candidate = Join-Path $found.FullName 'python.exe'
        if (Test-Path $candidate) {
            $pyPath = $candidate
        }
    }
}

# Try PATH
if (-not $pyPath) {
    $pyPath = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($pyPath) {
        $major = & $pyPath -c "import sys; print(sys.version_info[0])" 2>$null
        if ($major -ne '3') {
            $pyPath = $null
        }
    }
}

if (-not $pyPath) {
    Write-Host "Python 3 not found. Installing via winget..."
    winget install Python.Python.3 --accept-source-agreements --accept-package-agreements

    $found = Get-ChildItem $pyBase -Directory |
    Where-Object { $_.Name -match '^Python3' } |
    Sort-Object Name -Descending |
    Select-Object -First 1

    if ($found) {
        $pyPath = Join-Path $found.FullName 'python.exe'
    }

    if (-not $pyPath -or -not (Test-Path $pyPath)) {
        Write-Error "Python installation failed. Please install Python 3 manually."
        exit 1
    }

    Write-Host "Python installed."
}

$ver = & $pyPath --version
Write-Host "Using: $ver ($pyPath)"

# Install dependencies
$deps = @(
    'opencv-python'
    'numpy'
    'mss'
    'pygetwindow'
    'pydirectinput-rgx'
    'pyyaml'
)

Write-Host "Installing dependencies..."
& $pyPath -m pip install --upgrade pip -q
& $pyPath -m pip install $deps -q

Write-Host "Verifying imports..."
$check = & $pyPath -c "
import cv2, numpy, mss, pygetwindow, pydirectinput, yaml
print('All imports OK')
" 2>&1

if ($check -match 'All imports OK') {
    Write-Host $check
}
else {
    Write-Error "Import check failed: $check"
    exit 1
}

Write-Host "Done. Run: & '$pyPath' cli.py <workflow>"
