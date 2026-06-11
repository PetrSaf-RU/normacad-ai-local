param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [Parameter(Mandatory = $true)]
    [string]$OutputJson,
    [string]$SampleId = "",
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [string]$VisionModel = "qwen2.5vl:7b",
    [string]$SourceUrl = "",
    [string]$DocumentClass = "assembly_drawing",
    [string]$License = "",
    [string]$Attribution = ""
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$image = (Resolve-Path -LiteralPath $ImagePath).Path
if (-not $SampleId) {
    $SampleId = ([IO.Path]::GetFileNameWithoutExtension($image) -replace '[^A-Za-z0-9_-]', '_').ToLowerInvariant()
}
$prompt = Get-Content -LiteralPath (Join-Path $scriptRoot "legacy-analysis-prompt.txt") -Raw -Encoding utf8
$bytes = [IO.File]::ReadAllBytes($image)
$payload = @{
    model = $VisionModel
    stream = $false
    format = "json"
    messages = @(
        @{
            role = "user"
            content = $prompt
            images = @([Convert]::ToBase64String($bytes))
        }
    )
    options = @{
        temperature = 0.1
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod `
    -Uri ($OllamaUrl.TrimEnd("/") + "/api/chat") `
    -Method Post `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($payload))
$legacyPath = [IO.Path]::ChangeExtension($OutputJson, ".legacy.json")
$response.message.content |
    Set-Content -LiteralPath $legacyPath -Encoding utf8

& (Join-Path $scriptRoot "Convert-LegacyAnalysisToV2.ps1") `
    -InputJson $legacyPath `
    -OutputJson $OutputJson `
    -SampleId $SampleId `
    -SourceFileName ([IO.Path]::GetFileName($image)) `
    -SourceUrl $SourceUrl `
    -DocumentClass $DocumentClass `
    -License $License `
    -Attribution $Attribution `
    -VisionModel $VisionModel `
    -TextModel "legacy-adapter"
