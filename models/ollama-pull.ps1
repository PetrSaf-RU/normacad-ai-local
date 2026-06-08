param(
    [string]$TextModel = "qwen2.5-coder:7b",
    [string]$VisionModel = "qwen2.5vl:7b"
)

$ErrorActionPreference = "Stop"

$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
$ollamaPath = if ($ollamaCommand) { $ollamaCommand.Source } else { $null }
if (-not $ollamaPath) {
    $defaultPath = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (Test-Path $defaultPath) {
        $ollamaPath = $defaultPath
    } else {
        throw "Ollama не найден. Установите Ollama: https://ollama.com/download"
    }
}

Write-Host "Pulling text model: $TextModel"
& $ollamaPath pull $TextModel

Write-Host "Pulling vision model: $VisionModel"
& $ollamaPath pull $VisionModel

Write-Host "Available models:"
& $ollamaPath list
