param(
    [string]$Url = "http://127.0.0.1:8000"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$ollama = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $ollama) {
    $ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
    $ollamaPath = if ($ollamaCommand) { $ollamaCommand.Source } else { $null }
    if (-not $ollamaPath) {
        $defaultPath = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
        if (Test-Path $defaultPath) {
            $ollamaPath = $defaultPath
        }
    }
    if (-not $ollamaPath) {
        throw "Ollama не найден. Сначала выполните .\setup.ps1"
    }
    Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Push-Location $projectRoot
try {
    dotnet run --urls $Url
} finally {
    Pop-Location
}
