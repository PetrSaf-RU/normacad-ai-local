param(
    [string]$Server = "http://127.0.0.1:8000",
    [string]$Path = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path $PSScriptRoot "..\standards\inbox"
}

$uri = "$Server/api/standards/import"
Write-Host "Importing standards from: $Path"
$result = curl.exe -s -X POST -F "path=$Path" $uri
$result | ConvertFrom-Json | ConvertTo-Json -Depth 6
