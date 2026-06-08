param(
    [string]$Repository = "PetrSaf-RU/normacad-ai-local",
    [string]$ReleaseTag = "models-v1",
    [string]$ModelsRoot = "",
    [string]$AssetDirectory = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$assetManifestPath = Join-Path $scriptRoot "model-assets.json"

if (-not (Test-Path $assetManifestPath)) {
    throw "Не найден models/model-assets.json."
}

if (-not $ModelsRoot) {
    $ModelsRoot = if ($env:OLLAMA_MODELS) {
        $env:OLLAMA_MODELS
    } else {
        Join-Path $env:USERPROFILE ".ollama\models"
    }
}

$ModelsRoot = [System.IO.Path]::GetFullPath($ModelsRoot)
$blobRoot = Join-Path $ModelsRoot "blobs"
$manifestRoot = Join-Path $ModelsRoot "manifests"
$downloadRoot = Join-Path $env:TEMP "normacad-ai-models-$ReleaseTag"
$baseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"

New-Item -ItemType Directory -Force -Path $blobRoot, $manifestRoot, $downloadRoot | Out-Null
$assetManifest = Get-Content $assetManifestPath -Raw -Encoding utf8 | ConvertFrom-Json

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-Asset([string]$Name, [string]$ExpectedHash) {
    if ($AssetDirectory) {
        $localAsset = Join-Path $AssetDirectory $Name
        if (-not (Test-Path $localAsset)) {
            throw "Не найден локальный asset: $localAsset"
        }
        if ((Get-Sha256 $localAsset) -ne $ExpectedHash) {
            throw "Контрольная сумма $Name не совпадает."
        }
        return $localAsset
    }

    $target = Join-Path $downloadRoot $Name
    if ((Test-Path $target) -and (Get-Sha256 $target) -eq $ExpectedHash) {
        return $target
    }

    Write-Host "Downloading $Name"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --retry 3 --output $target "$baseUrl/$Name"
        if ($LASTEXITCODE -ne 0) {
            throw "Не удалось скачать $Name."
        }
    } else {
        Invoke-WebRequest -Uri "$baseUrl/$Name" -OutFile $target
    }

    if ((Get-Sha256 $target) -ne $ExpectedHash) {
        throw "Контрольная сумма $Name не совпадает."
    }
    return $target
}

foreach ($model in $assetManifest.models) {
    $targetBlob = Join-Path $blobRoot ("sha256-" + $model.digest)
    if (-not $Force -and (Test-Path $targetBlob)) {
        if ((Get-Sha256 $targetBlob) -eq $model.digest) {
            Write-Host "$($model.name): model blob already installed."
            continue
        }
    }

    $temporaryBlob = "$targetBlob.partial"
    if (Test-Path $temporaryBlob) {
        Remove-Item -LiteralPath $temporaryBlob -Force
    }

    $output = [System.IO.File]::Open(
        $temporaryBlob,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        foreach ($chunk in $model.chunks) {
            $chunkPath = Download-Asset $chunk.name $chunk.sha256
            $input = [System.IO.File]::OpenRead($chunkPath)
            try {
                $input.CopyTo($output)
            } finally {
                $input.Dispose()
            }
        }
    } finally {
        $output.Dispose()
    }

    if ((Get-Sha256 $temporaryBlob) -ne $model.digest) {
        Remove-Item -LiteralPath $temporaryBlob -Force
        throw "Итоговая контрольная сумма $($model.name) не совпадает."
    }
    Move-Item -LiteralPath $temporaryBlob -Destination $targetBlob -Force
    Write-Host "$($model.name): model blob installed."
}

$bundleRoot = Join-Path $scriptRoot "ollama-bundle"
if (-not (Test-Path $bundleRoot)) {
    throw "Не найден models/ollama-bundle."
}

Copy-Item -Path (Join-Path $bundleRoot "blobs\*") -Destination $blobRoot -Force
$manifestSourceRoot = (Resolve-Path (Join-Path $bundleRoot "manifests")).Path.TrimEnd("\")
Get-ChildItem $manifestSourceRoot -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($manifestSourceRoot.Length).TrimStart(
        [char[]]@("\", "/")
    )
    $target = Join-Path $manifestRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}

Write-Host ""
Write-Host "Локальные модели установлены в $ModelsRoot"
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    & ollama list
}
