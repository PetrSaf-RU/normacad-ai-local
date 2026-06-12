param(
    [string]$Manifest = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Manifest)) {
    $Manifest = Join-Path $PSScriptRoot "..\standards\catalog\download_manifest.csv"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $PSScriptRoot "..\standards\inbox"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$items = Import-Csv -Path $Manifest
foreach ($item in $items) {
    if ([string]::IsNullOrWhiteSpace($item.Url) -or [string]::IsNullOrWhiteSpace($item.FileName)) {
        continue
    }

    $target = Join-Path $OutDir $item.FileName
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Write-Host "Downloading $($item.Url) -> $target"
    Invoke-WebRequest -Uri $item.Url -OutFile $target
}

Write-Host "Done. Run tools\import-standards.ps1 after downloading."
