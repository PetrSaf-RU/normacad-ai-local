$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$trainingRoot = Join-Path $root "training-data"
$exportsRoot = Join-Path $trainingRoot "teamlead-exports"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$exportDirectory = Join-Path $exportsRoot "normacad-training-review-$stamp"
$zipPath = "$exportDirectory.zip"

& (Join-Path $root "scripts\update-training-index.ps1")

New-Item -ItemType Directory -Force -Path $exportDirectory | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $trainingRoot "pending_review") `
    -Destination $exportDirectory `
    -Recurse
foreach ($reviewDirectory in "approved", "rejected", "superseded") {
    $reviewPath = Join-Path $trainingRoot $reviewDirectory
    if (Test-Path -LiteralPath $reviewPath) {
        Copy-Item `
            -LiteralPath $reviewPath `
            -Destination $exportDirectory `
            -Recurse
    }
}
Copy-Item `
    -LiteralPath (Join-Path $trainingRoot "manifests") `
    -Destination $exportDirectory `
    -Recurse
Copy-Item `
    -LiteralPath (Join-Path $trainingRoot "annotation-schema.json") `
    -Destination $exportDirectory
Copy-Item `
    -LiteralPath (Join-Path $trainingRoot "TEAMLEAD-RU.md") `
    -Destination $exportDirectory

Compress-Archive -Path (Join-Path $exportDirectory "*") -DestinationPath $zipPath

Write-Host "TEAMLEAD_DIRECTORY=$exportDirectory"
Write-Host "TEAMLEAD_ZIP=$zipPath"
