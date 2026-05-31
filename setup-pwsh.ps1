<#
RUN: .\setup.ps1
Pulls OpenCvSharp + YamlDotNet DLLs from NuGet. Skips if already present.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dir = Join-Path $PSScriptRoot 'lib'
New-Item -Path $dir -ItemType Directory -Force | Out-Null

$requiredDlls = @('OpenCvSharp.dll', 'OpenCvSharpExtern.dll', 'YamlDotNet.dll')
$missing = $requiredDlls | Where-Object { -not (Test-Path (Join-Path $dir $_)) }
if (-not $missing) {
    Write-Host 'All DLLs already present. Nothing to do.'
    exit 0
}

Write-Host "Missing: $($missing -join ', ')"

function Resolve-LatestVersion([string]$packageId) {
    $id = $packageId.ToLower()
    $json = Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/$id/index.json"
    return $json.versions[-1]
}

function Save-Package([string]$packageId, [string]$version) {
    $id = $packageId.ToLower()
    $url = "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg"
    $dest = Join-Path $dir "$id.nupkg"
    Write-Host "  $packageId $version"
    Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
    return $dest
}

function Expand-DllEntry([System.IO.Compression.ZipArchive]$archive, [string]$entryPath, [string]$fileName) {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq $entryPath } | Select-Object -First 1
    if (-not $entry) {
        throw "Entry not found: $entryPath"
    }

    $dest = Join-Path $dir $fileName
    $stream = $entry.Open()
    try {
        $fs = [System.IO.File]::Create($dest)
        try {
            $stream.CopyTo($fs)
        } finally {
            $fs.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    Write-Host "  -> $fileName"
}

# OpenCvSharp
if (-not (Test-Path (Join-Path $dir 'OpenCvSharp.dll')) -or -not (Test-Path (Join-Path $dir 'OpenCvSharpExtern.dll'))) {
    $managedVer = Resolve-LatestVersion 'OpenCvSharp4'
    $nativeVer = Resolve-LatestVersion 'OpenCvSharp4.runtime.win'

    Write-Host 'Downloading OpenCvSharp:'
    $managedPkg = Save-Package 'OpenCvSharp4' $managedVer
    $nativePkg = Save-Package 'OpenCvSharp4.runtime.win' $nativeVer

    Write-Host 'Extracting OpenCvSharp:'
    $zip = [System.IO.Compression.ZipFile]::OpenRead($managedPkg)
    try {
        $net8 = $zip.Entries | Where-Object { $_.FullName -eq 'lib/net8.0/OpenCvSharp.dll' }
        if ($net8) {
            Expand-DllEntry $zip 'lib/net8.0/OpenCvSharp.dll' 'OpenCvSharp.dll'
        } else {
            Expand-DllEntry $zip 'lib/netstandard2.0/OpenCvSharp.dll' 'OpenCvSharp.dll'
        }
    } finally {
        $zip.Dispose()
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($nativePkg)
    try {
        $natives = $zip.Entries | Where-Object { $_.FullName -like 'runtimes/win-x64/native/*.dll' }
        foreach ($e in $natives) {
            Expand-DllEntry $zip $e.FullName $e.Name
        }
    } finally {
        $zip.Dispose()
    }

    Remove-Item $managedPkg, $nativePkg
} else {
    Write-Host 'OpenCvSharp: already present, skipping.'
}

# YamlDotNet
if (-not (Test-Path (Join-Path $dir 'YamlDotNet.dll'))) {
    $yamlVer = Resolve-LatestVersion 'YamlDotNet'

    Write-Host 'Downloading YamlDotNet:'
    $yamlPkg = Save-Package 'YamlDotNet' $yamlVer

    Write-Host 'Extracting YamlDotNet:'
    $zip = [System.IO.Compression.ZipFile]::OpenRead($yamlPkg)
    try {
        $net8 = $zip.Entries | Where-Object { $_.FullName -eq 'lib/net8.0/YamlDotNet.dll' }
        if ($net8) {
            Expand-DllEntry $zip 'lib/net8.0/YamlDotNet.dll' 'YamlDotNet.dll'
        } else {
            $best = $zip.Entries | Where-Object { $_.FullName -like 'lib/*/YamlDotNet.dll' } | Select-Object -Last 1
            Expand-DllEntry $zip $best.FullName 'YamlDotNet.dll'
        }
    } finally {
        $zip.Dispose()
    }

    Remove-Item $yamlPkg
} else {
    Write-Host 'YamlDotNet: already present, skipping.'
}

Write-Host "Done. DLLs in: $dir"
