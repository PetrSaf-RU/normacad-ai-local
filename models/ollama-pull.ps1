param(
    [string]$TextModel = "qwen2.5-coder:7b",
    [string]$VisionModel = "qwen2.5vl:7b"
)

$ErrorActionPreference = "Stop"

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    $defaultPath = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (Test-Path $defaultPath) {
        $ollama = Get-Item $defaultPath
    } else {
        throw "Ollama не найден. Установите Ollama: https://ollama.com/download"
    }
}

Write-Host "Pulling text model: $TextModel"
& $ollama.Source pull $TextModel

Write-Host "Pulling vision model: $VisionModel"
& $ollama.Source pull $VisionModel

Write-Host "Available models:"
& $ollama.Source list
