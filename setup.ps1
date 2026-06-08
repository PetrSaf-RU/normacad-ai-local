param(
    [switch]$SkipPrerequisites,
    [switch]$UseOllamaRegistry
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not $SkipPrerequisites) {
    if (-not (Test-Command "dotnet")) {
        if (-not (Test-Command "winget")) {
            throw ".NET SDK 10 не найден, а winget недоступен."
        }
        winget install --id Microsoft.DotNet.SDK.10 --exact --accept-package-agreements --accept-source-agreements
    }

    if (-not (Test-Command "ollama")) {
        if (-not (Test-Command "winget")) {
            throw "Ollama не найден, а winget недоступен."
        }
        winget install --id Ollama.Ollama --exact --accept-package-agreements --accept-source-agreements
    }

    $tesseract = "C:\Program Files\Tesseract-OCR\tesseract.exe"
    if (-not (Test-Path $tesseract) -and -not (Test-Command "tesseract")) {
        if (-not (Test-Command "winget")) {
            throw "Tesseract OCR не найден, а winget недоступен."
        }
        winget install --id UB-Mannheim.TesseractOCR --exact --accept-package-agreements --accept-source-agreements
    }
}

$modelInstaller = Join-Path $projectRoot "models\install-local-ai.ps1"
if ($UseOllamaRegistry) {
    & (Join-Path $projectRoot "models\ollama-pull.ps1")
} else {
    & $modelInstaller
}

Push-Location $projectRoot
try {
    dotnet restore
    dotnet build
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "NormaCAD AI установлен."
Write-Host "Запуск: .\start.ps1"
