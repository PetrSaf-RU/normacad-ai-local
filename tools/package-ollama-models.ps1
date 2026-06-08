param(
    [string]$ModelsRoot = "",
    [string]$OutputPath = "",
    [long]$ChunkSize = 1900000000
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ModelsRoot) {
    $ModelsRoot = if ($env:OLLAMA_MODELS) {
        $env:OLLAMA_MODELS
    } else {
        Join-Path $env:USERPROFILE ".ollama\models"
    }
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot "release-assets"
}

$models = @(
    @{
        name = "qwen2.5-coder:7b"
        digest = "60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463"
        prefix = "qwen2.5-coder-7b"
    },
    @{
        name = "qwen2.5vl:7b"
        digest = "a99b7f834d754b88f122d865f32758ba9f0994a83f8363df2c1e71c17605a025"
        prefix = "qwen2.5vl-7b"
    }
)

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$manifest = @{ schema_version = 1; models = @() }
$buffer = New-Object byte[] (8MB)

foreach ($model in $models) {
    $source = Join-Path $ModelsRoot ("blobs\sha256-" + $model.digest)
    if (-not (Test-Path $source)) {
        throw "Не найден model blob: $source"
    }

    $chunks = @()
    $input = [System.IO.File]::OpenRead($source)
    try {
        $part = 1
        while ($input.Position -lt $input.Length) {
            $chunkName = "{0}.part{1:D3}" -f $model.prefix, $part
            $chunkPath = Join-Path $OutputPath $chunkName
            $output = [System.IO.File]::Create($chunkPath)
            try {
                $remaining = [Math]::Min($ChunkSize, $input.Length - $input.Position)
                while ($remaining -gt 0) {
                    $readSize = [int][Math]::Min($buffer.Length, $remaining)
                    $read = $input.Read($buffer, 0, $readSize)
                    if ($read -le 0) {
                        break
                    }
                    $output.Write($buffer, 0, $read)
                    $remaining -= $read
                }
            } finally {
                $output.Dispose()
            }

            $chunkFile = Get-Item $chunkPath
            $chunks += @{
                name = $chunkName
                size = $chunkFile.Length
                sha256 = (Get-FileHash $chunkPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            Write-Host "$chunkName ($($chunkFile.Length) bytes)"
            $part++
        }
    } finally {
        $input.Dispose()
    }

    $sourceFile = Get-Item $source
    $manifest.models += @{
        name = $model.name
        digest = $model.digest
        size = $sourceFile.Length
        chunks = $chunks
    }
}

$manifestPath = Join-Path $projectRoot "models\model-assets.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath -Encoding utf8
Write-Host "Manifest written to $manifestPath"
