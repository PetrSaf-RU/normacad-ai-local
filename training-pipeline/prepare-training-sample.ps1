param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    [string]$SourceUrl = "",
    [string]$License = "unknown",
    [string]$Attribution = "",
    [string]$Preprocessing = "none",
    [string]$SampleId = "",
    [ValidateSet(
        "production_drawing",
        "assembly_drawing",
        "schematic",
        "reference_cutaway",
        "historical_drawing",
        "unknown"
    )]
    [string]$DocumentClass = "unknown",
    [switch]$ReuseVisionLog,
    [switch]$AllowDuplicateSource
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$trainingRoot = Join-Path $root "training-data"
$incomingRoot = Join-Path $trainingRoot "incoming"
$pendingRoot = Join-Path $trainingRoot "pending_review"
$logsRoot = Join-Path $trainingRoot "logs"
$manifestsRoot = Join-Path $trainingRoot "manifests"

foreach ($directory in $incomingRoot, $pendingRoot, $logsRoot, $manifestsRoot) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
foreach ($directory in (Join-Path $trainingRoot "approved"), (Join-Path $trainingRoot "rejected")) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Invoke-LocalVision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string]$PassName
    )

    $imageBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))
    $attempt = 0
    $content = ""
    $response = $null
    $jsonValid = $false
    do {
        $attempt++
        $attemptPrompt = $Prompt
        if ($attempt -gt 1) {
            $attemptPrompt += @"

The previous response was not valid JSON. Return exactly one complete JSON
object. Do not add prose, markdown fences, comments, or trailing text.
"@
        }
        $body = @{
            model = "qwen2.5vl:7b"
            format = "json"
            messages = @(
                @{
                    role = "user"
                    content = $attemptPrompt
                    images = @($imageBase64)
                }
            )
            stream = $false
            options = @{
                temperature = 0.05
                num_ctx = 8192
                num_predict = 2500
            }
        } | ConvertTo-Json -Depth 12 -Compress
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "http://127.0.0.1:11434/api/chat" `
            -ContentType "application/json; charset=utf-8" `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -TimeoutSec 900
        $content = [string]$response.message.content
        if (-not $content) {
            continue
        }
        try {
            $parsed = $content | ConvertFrom-Json
            $jsonValid = $null -ne $parsed
        } catch {
            $jsonValid = $false
        }
    } while (-not $jsonValid -and $attempt -lt 2)

    if (-not $content) {
        throw "Vision model returned an empty response for $PassName."
    }
    return [ordered]@{
        pass = $PassName
        image = [IO.Path]::GetFileName($ImagePath)
        content = $content
        json_valid = $jsonValid
        attempts = $attempt
        eval_count = $response.eval_count
        total_duration = $response.total_duration
    }
}

function New-DrawingTiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    Add-Type -AssemblyName System.Drawing
    $sourceImage = [Drawing.Image]::FromFile($ImagePath)
    try {
        if ($sourceImage.Width -lt 1200 -and $sourceImage.Height -lt 900) {
            return @()
        }
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        $tiles = @()
        $aspectRatio = $sourceImage.Width / [double]$sourceImage.Height
        $columns = 2
        $rows = 2
        if ($aspectRatio -ge 1.6) {
            $columns = 4
            $rows = 2
        } elseif ($aspectRatio -le 0.625) {
            $columns = 2
            $rows = 4
        }
        $cellWidth = [Math]::Ceiling($sourceImage.Width / $columns)
        $cellHeight = [Math]::Ceiling($sourceImage.Height / $rows)
        $overlapX = [Math]::Max(40, [Math]::Floor($sourceImage.Width * 0.06))
        $overlapY = [Math]::Max(40, [Math]::Floor($sourceImage.Height * 0.06))

        for ($row = 0; $row -lt $rows; $row++) {
            for ($column = 0; $column -lt $columns; $column++) {
                $x1 = [Math]::Max(0, $column * $cellWidth - $overlapX)
                $y1 = [Math]::Max(0, $row * $cellHeight - $overlapY)
                $x2 = [Math]::Min($sourceImage.Width, ($column + 1) * $cellWidth + $overlapX)
                $y2 = [Math]::Min($sourceImage.Height, ($row + 1) * $cellHeight + $overlapY)
                $width = $x2 - $x1
                $height = $y2 - $y1
                $tile = New-Object Drawing.Bitmap($width, $height)
                $graphics = [Drawing.Graphics]::FromImage($tile)
                try {
                    $graphics.DrawImage(
                        $sourceImage,
                        [Drawing.Rectangle]::new(0, 0, $width, $height),
                        [Drawing.Rectangle]::new($x1, $y1, $width, $height),
                        [Drawing.GraphicsUnit]::Pixel
                    )
                    $tilePath = Join-Path $OutputDirectory "tile-r$($row + 1)-c$($column + 1).jpg"
                    $tile.Save($tilePath, [Drawing.Imaging.ImageFormat]::Jpeg)
                    $tiles += $tilePath
                } finally {
                    $graphics.Dispose()
                    $tile.Dispose()
                }
            }
        }
        return $tiles
    } finally {
        $sourceImage.Dispose()
    }
}

function ConvertFrom-ModelJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $cleaned = $Text.Trim()
    if ($cleaned.StartsWith('```')) {
        $cleaned = $cleaned -replace '^```(?:json)?\s*', ''
        $cleaned = $cleaned -replace '\s*```$', ''
    }
    $firstBrace = $cleaned.IndexOf("{")
    $lastBrace = $cleaned.LastIndexOf("}")
    if ($firstBrace -lt 0 -or $lastBrace -le $firstBrace) {
        throw "The model response does not contain a JSON object."
    }
    return $cleaned.Substring($firstBrace, $lastBrace - $firstBrace + 1) |
        ConvertFrom-Json
}

function Test-AnnotationSchema {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Annotation
    )

    $errors = @()
    foreach ($property in "drawing_summary", "observed_entities", "dimensions_and_designations", "possible_violations", "uncertainties") {
        if (-not $Annotation.PSObject.Properties[$property]) {
            $errors += "missing_required_property:$property"
        }
    }
    if ($errors.Count) {
        return [pscustomobject]@{ valid = $false; errors = $errors }
    }

    $summary = $Annotation.drawing_summary
    foreach ($property in "drawing_type", "subject", "views", "complexity") {
        if (-not $summary.PSObject.Properties[$property]) {
            $errors += "drawing_summary.missing:$property"
        }
    }
    if ([string]$summary.complexity -notin @("low", "medium", "high", "very_high")) {
        $errors += "drawing_summary.invalid_complexity:$($summary.complexity)"
    }
    if ($summary.views -is [string] -or $null -eq $summary.views) {
        $errors += "drawing_summary.views_not_array"
    }

    $index = 0
    foreach ($item in @($Annotation.observed_entities)) {
        foreach ($property in "entity", "evidence", "location", "confidence") {
            if (-not $item.PSObject.Properties[$property]) {
                $errors += "observed_entities[$index].missing:$property"
            }
        }
        if (
            $item.PSObject.Properties["confidence"] -and
            ([double]$item.confidence -lt 0 -or [double]$item.confidence -gt 1)
        ) {
            $errors += "observed_entities[$index].confidence_out_of_range"
        }
        $index++
    }

    $index = 0
    foreach ($item in @($Annotation.dimensions_and_designations)) {
        foreach ($property in "text", "location", "confidence") {
            if (-not $item.PSObject.Properties[$property]) {
                $errors += "dimensions_and_designations[$index].missing:$property"
            }
        }
        if (
            $item.PSObject.Properties["confidence"] -and
            ([double]$item.confidence -lt 0 -or [double]$item.confidence -gt 1)
        ) {
            $errors += "dimensions_and_designations[$index].confidence_out_of_range"
        }
        $index++
    }

    $index = 0
    foreach ($item in @($Annotation.possible_violations)) {
        foreach ($property in "category", "description", "evidence", "severity", "confidence", "standard_reference", "human_review_required") {
            if (-not $item.PSObject.Properties[$property]) {
                $errors += "possible_violations[$index].missing:$property"
            }
        }
        if ($item.standard_reference) {
            foreach ($property in "standard_code", "title", "source_url", "local_source_path", "local_source_sha256", "evidence_status", "clause_number", "source_quote_short") {
                if (-not $item.standard_reference.PSObject.Properties[$property]) {
                    $errors += "possible_violations[$index].standard_reference.missing:$property"
                }
            }
            if ([string]$item.standard_reference.evidence_status -notin @("metadata_only", "local_mirror_human_review", "full_text_verified")) {
                $errors += "possible_violations[$index].standard_reference.invalid_evidence_status"
            }
            if (
                [string]$item.standard_reference.evidence_status -eq "metadata_only" -and
                ($item.standard_reference.clause_number -or $item.standard_reference.source_quote_short)
            ) {
                $errors += "possible_violations[$index].metadata_only_must_not_claim_clause"
            }
        }
        if ([string]$item.severity -notin @("info", "warning", "error")) {
            $errors += "possible_violations[$index].invalid_severity:$($item.severity)"
        }
        if (
            $item.PSObject.Properties["confidence"] -and
            ([double]$item.confidence -lt 0 -or [double]$item.confidence -gt 1)
        ) {
            $errors += "possible_violations[$index].confidence_out_of_range"
        }
        if ($item.human_review_required -ne $true) {
            $errors += "possible_violations[$index].human_review_required_not_true"
        }
        $index++
    }

    return [pscustomobject]@{
        valid = $errors.Count -eq 0
        errors = @($errors)
    }
}

$source = (Resolve-Path -LiteralPath $InputFile).Path
if (-not $SampleId) {
    $baseName = [IO.Path]::GetFileNameWithoutExtension($source)
    $safeName = ($baseName -replace "[^a-zA-Z0-9_-]", "_").Trim("_")
    if (-not $safeName) {
        $safeName = "drawing"
    }
    $SampleId = "{0}_{1}" -f $safeName, (Get-Date -Format "yyyyMMdd_HHmmss")
}

& (Join-Path $root "scripts\start-portable.ps1") -NoBrowser

$extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
$incomingName = "$SampleId$extension"
$incomingPath = Join-Path $incomingRoot $incomingName
Copy-Item -LiteralPath $source -Destination $incomingPath -Force
$sha256 = (Get-FileHash -LiteralPath $incomingPath -Algorithm SHA256).Hash.ToLowerInvariant()

if (-not $AllowDuplicateSource) {
    $duplicates = @()
    foreach ($manifestFile in Get-ChildItem -LiteralPath $manifestsRoot -Filter *.json -File -ErrorAction SilentlyContinue) {
        if ($manifestFile.Name -eq "training-index.json") {
            continue
        }
        try {
            $manifestData = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding utf8 |
                ConvertFrom-Json
            if (
                $manifestData.source_sha256 -eq $sha256 -and
                $manifestData.sample_id -ne $SampleId
            ) {
                $duplicates += [string]$manifestData.sample_id
            }
        } catch {
            continue
        }
    }
    if ($duplicates.Count) {
        Remove-Item -LiteralPath $incomingPath -Force -ErrorAction SilentlyContinue
        throw "Duplicate source SHA-256 already exists in sample(s): $($duplicates -join ', '). Use -AllowDuplicateSource only for an intentional pipeline comparison."
    }
}

$catalogPath = Join-Path $root "standards\catalog\eskd_manifest.csv"
if (-not (Test-Path -LiteralPath $catalogPath)) {
    $catalogPath = Join-Path $root "app\standards\catalog\eskd_manifest.csv"
}
$standardsCatalog = ""
$localStandardReferences = @{}
if (Test-Path -LiteralPath $catalogPath) {
    $standardsCatalog = @(
        Import-Csv -LiteralPath $catalogPath |
            ForEach-Object {
                $fileName = ($_.Code -replace '^ГОСТ\s+', 'GOST_' -replace '\s+', '_') + ".html"
                $localPath = @(
                    Join-Path $root "standards\inbox\local-fulltext\$fileName"
                    Join-Path $root "app\standards\inbox\local-fulltext\$fileName"
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($localPath) {
                    $hash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    $localStandardReferences[$_.Code] = [pscustomobject]@{
                        standard_code = [string]$_.Code
                        title = [string]$_.Title
                        source_url = [string]$_.SourceUrl
                        local_source_path = [IO.Path]::GetFullPath($localPath)
                        local_source_sha256 = $hash
                        evidence_status = "local_mirror_human_review"
                        clause_number = $null
                        source_quote_short = $null
                    }
                    "- $($_.Code) | $($_.Title) | official=$($_.SourceUrl) | local=$localPath | sha256=$hash | local_mirror_human_review"
                } else {
                    "- $($_.Code) | $($_.Title) | official=$($_.SourceUrl) | metadata_only"
                }
            }
    ) -join "`n"
}

$visionPrompt = @"
Analyze this technical drawing as a preliminary CAD drafting reviewer.
Return exactly one JSON object and no markdown. Do not invent dimensions,
dates, labels, standards, defects, or missing views. A possible violation must
be tied to concrete visible evidence. For a dense drawing, list at least eight
separate visible components. Keep uncertain readings in uncertainties.
Every possible_violations item must reference one relevant standard from the
local catalog below and copy its exact official URL. Catalog metadata does not
prove a violation, so use evidence_status=metadata_only, clause_number=null and
source_quote_short=null. A downloaded local copy uses
evidence_status=local_mirror_human_review and must copy its exact local path and
SHA-256 from the catalog. If no catalog entry directly covers the candidate,
move it to uncertainties instead of possible_violations. Never invent a GOST
code, URL, clause, quote, table or appendix.

Local official standards catalog:
$standardsCatalog

Required format:
{
  "drawing_summary": {
    "drawing_type": "string",
    "subject": "string",
    "views": ["string"],
    "complexity": "low|medium|high|very_high"
  },
  "observed_entities": [
    {
      "entity": "string",
      "evidence": "what is visibly present",
      "location": "location on the sheet or crop",
      "confidence": 0.0
    }
  ],
  "dimensions_and_designations": [
    {
      "text": "only clearly readable text or dimension",
      "location": "string",
      "confidence": 0.0
    }
  ],
  "possible_violations": [
    {
      "category": "string",
      "description": "candidate issue, not a proven violation",
      "evidence": "specific visible evidence",
      "severity": "info|warning|error",
      "confidence": 0.0,
      "standard_reference": {
        "standard_code": "exact code from the supplied local standards catalog",
        "title": "official standard title",
        "source_url": "official protect.gost.ru URL",
        "local_source_path": "absolute path to the local standard copy",
        "local_source_sha256": "64 lowercase hexadecimal characters",
        "evidence_status": "metadata_only|local_mirror_human_review|full_text_verified",
        "clause_number": null,
        "source_quote_short": null
      },
      "human_review_required": true
    }
  ],
  "uncertainties": ["string"]
}
"@

$visionOutput = Join-Path $logsRoot "$SampleId.vision-api.json"
$tileRoot = Join-Path $logsRoot "$SampleId.tiles"
if ($ReuseVisionLog -and (Test-Path $visionOutput)) {
    $visionLog = Get-Content -LiteralPath $visionOutput -Raw -Encoding utf8 |
        ConvertFrom-Json
    $visionPasses = @($visionLog.passes)
    $tiles = @(
        Get-ChildItem -LiteralPath $tileRoot -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
} else {
    $visionPasses = @()
    $visionPasses += Invoke-LocalVision `
        -ImagePath $incomingPath `
        -PassName "global" `
        -Prompt ($visionPrompt + "`nThis is the full-sheet overview. Describe the overall layout first.")

    $tiles = @(New-DrawingTiles -ImagePath $incomingPath -OutputDirectory $tileRoot)
    for ($index = 0; $index -lt $tiles.Count; $index++) {
        $tileName = "tile_{0}" -f ($index + 1)
        $tilePrompt = $visionPrompt + @"

This is enlarged crop $($index + 1) of $($tiles.Count) from the full sheet.
Analyze only what is visibly present in this crop. Do not claim that the full
sheet lacks other views, dimensions, or labels. Give crop-relative locations.
"@
        $visionPasses += Invoke-LocalVision `
            -ImagePath $tiles[$index] `
            -PassName $tileName `
            -Prompt $tilePrompt
    }
    $visionLog = [ordered]@{
        model = "qwen2.5vl:7b"
        pass_count = $visionPasses.Count
        passes = $visionPasses
    }
    $visionLog | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $visionOutput -Encoding utf8
}
$visionAnswer = ($visionPasses | ForEach-Object {
    "=== $($_.pass) ===`n$($_.content)"
}) -join "`n`n"

$parsedPasses = @()
$parseFailures = @()
foreach ($pass in $visionPasses) {
    try {
        $parsedPasses += [pscustomobject]@{
            pass = $pass.pass
            data = ConvertFrom-ModelJson -Text $pass.content
        }
    } catch {
        $parseFailures += $pass.pass
    }
}
if (-not $parsedPasses.Count) {
    throw "None of the vision passes returned valid JSON."
}

$globalData = @($parsedPasses | Where-Object { $_.pass -eq "global" })[0].data
$views = @($parsedPasses | ForEach-Object { @($_.data.drawing_summary.views) }) |
    Where-Object { $_ } |
    Select-Object -Unique

$entities = @()
$entityKeys = @{}
foreach ($item in @($parsedPasses | ForEach-Object { @($_.data.observed_entities) })) {
    $requiredEntityFields = @(
        $item.entity,
        $item.evidence,
        $item.location,
        $item.confidence
    )
    if (@($requiredEntityFields | Where-Object { $null -eq $_ -or ([string]$_).Trim().Length -eq 0 }).Count -gt 0) {
        continue
    }
    $entityConfidence = 0.0
    if (-not [double]::TryParse(
        ([string]$item.confidence),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$entityConfidence
    ) -or $entityConfidence -lt 0 -or $entityConfidence -gt 1) {
        continue
    }
    $key = ([string]$item.entity).Trim().ToLowerInvariant()
    if (-not $entityKeys.ContainsKey($key)) {
        $entityKeys[$key] = $true
        $entities += $item
    }
}

$dimensions = @()
$dimensionKeys = @{}
foreach ($item in @($parsedPasses | ForEach-Object { @($_.data.dimensions_and_designations) })) {
    $requiredDimensionFields = @(
        $item.text,
        $item.location,
        $item.confidence
    )
    if (@($requiredDimensionFields | Where-Object { $null -eq $_ -or ([string]$_).Trim().Length -eq 0 }).Count -gt 0) {
        continue
    }
    $dimensionConfidence = 0.0
    if (-not [double]::TryParse(
        ([string]$item.confidence),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$dimensionConfidence
    ) -or $dimensionConfidence -lt 0 -or $dimensionConfidence -gt 1) {
        continue
    }
    $key = ("{0}|{1}" -f $item.text, $item.location).ToLowerInvariant()
    if (-not $dimensionKeys.ContainsKey($key)) {
        $dimensionKeys[$key] = $true
        $dimensions += $item
    }
}

$uncertainties = @($parsedPasses | ForEach-Object { @($_.data.uncertainties) }) |
    Where-Object { $_ } |
    Select-Object -Unique
$violations = @()
$violationKeys = @{}
foreach ($item in @($parsedPasses | ForEach-Object { @($_.data.possible_violations) })) {
    $claimText = ("{0} {1} {2}" -f $item.category, $item.description, $item.evidence).ToLowerInvariant()
    $resolvedCode = if ($claimText -match 'dimension|размер|tolerance|допуск') {
        "ГОСТ 2.307-2011"
    } elseif ($claimText -match 'line|линия|штрих') {
        "ГОСТ 2.303-68"
    } elseif ($claimText -match 'font|text|letter|шрифт|надпис') {
        "ГОСТ 2.304-81"
    } elseif ($claimText -match 'view|section|cut|вид|разрез|сечен') {
        "ГОСТ 2.305-2008"
    } elseif ($claimText -match 'scale|масштаб') {
        "ГОСТ 2.302-68"
    } elseif ($claimText -match 'format|frame|sheet|формат|рамк|лист') {
        "ГОСТ 2.301-68"
    } else {
        $null
    }
    if (-not $resolvedCode -or -not $localStandardReferences.ContainsKey($resolvedCode)) {
        $uncertainties += "Кандидат не включен в issues: для категории '$($item.category)' не найдено локальное нормативное основание."
        continue
    }
    $item | Add-Member -NotePropertyName standard_reference -NotePropertyValue $localStandardReferences[$resolvedCode] -Force
    $requiredViolationFields = @(
        $item.category,
        $item.description,
        $item.evidence,
        $item.severity,
        $item.confidence,
        $item.standard_reference,
        $item.standard_reference.standard_code,
        $item.standard_reference.title,
        $item.standard_reference.source_url,
        $item.standard_reference.local_source_path,
        $item.standard_reference.local_source_sha256,
        $item.standard_reference.evidence_status
    )
    if (@($requiredViolationFields | Where-Object { $null -eq $_ -or ([string]$_).Trim().Length -eq 0 }).Count -gt 0) {
        continue
    }
    if ($item.severity -notin @("info", "warning", "error")) {
        continue
    }
    if ($item.standard_reference.evidence_status -notin @("metadata_only", "local_mirror_human_review", "full_text_verified")) {
        continue
    }
    if (
        $item.standard_reference.source_url -notmatch '^https://protect\.gost\.ru/' -or
        (
            $item.standard_reference.evidence_status -eq "metadata_only" -and
            ($item.standard_reference.clause_number -or $item.standard_reference.source_quote_short)
        )
    ) {
        continue
    }
    $confidence = 0.0
    if (-not [double]::TryParse(
        ([string]$item.confidence),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$confidence
    ) -or $confidence -lt 0 -or $confidence -gt 1) {
        continue
    }
    $key = ([string]$item.description).Trim().ToLowerInvariant()
    if (-not $violationKeys.ContainsKey($key)) {
        $violationKeys[$key] = $true
        $item | Add-Member `
            -NotePropertyName human_review_required `
            -NotePropertyValue $true `
            -Force
        $violations += $item
    }
}

if ($parseFailures.Count) {
    $uncertainties += "Не удалось разобрать JSON vision-проходов: $($parseFailures -join ', ')."
}

$annotation = [pscustomobject]@{
    drawing_summary = [pscustomobject]@{
        drawing_type = [string]$globalData.drawing_summary.drawing_type
        subject = [string]$globalData.drawing_summary.subject
        views = @($views)
        complexity = [string]$globalData.drawing_summary.complexity
    }
    observed_entities = @($entities)
    dimensions_and_designations = @($dimensions)
    possible_violations = @($violations)
    uncertainties = @($uncertainties)
}

$reviewPrompt = @"
Act as the second local model for CAD dataset quality control. Check the JSON
below. Do not rewrite the annotation and do not remove items. Do not copy the
placeholder phrases from this instruction. Populate every array with specific
findings from the supplied annotation; use an empty array when there is no
finding. Return only JSON with these keys:
{
  "consistency_score": 0.0,
  "issues": ["structural or logical problems"],
  "suspicious_claims": ["claims lacking sufficient visual evidence"],
  "recommended_review_focus": ["items an engineer should verify"]
}

Annotation:
$($annotation | ConvertTo-Json -Depth 20)
"@

$ollamaBody = @{
    model = "qwen2.5-coder:7b"
    format = "json"
    messages = @(
        @{
            role = "user"
            content = $reviewPrompt
        }
    )
    stream = $false
    options = @{
        temperature = 0
        num_ctx = 16384
        num_predict = 1500
    }
} | ConvertTo-Json -Depth 12

$coderResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:11434/api/chat" `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($ollamaBody)) `
    -TimeoutSec 900
$coderRaw = [string]$coderResponse.message.content
Set-Content -LiteralPath (Join-Path $logsRoot "$SampleId.coder.txt") -Value $coderRaw -Encoding utf8
$secondModelParseFailure = $false
try {
    $secondModelReview = ConvertFrom-ModelJson -Text $coderRaw
} catch {
    $secondModelParseFailure = $true
    $secondModelReview = [pscustomobject]@{
        consistency_score = 0
        issues = @("second_model_returned_non_json_review")
        suspicious_claims = @()
        recommended_review_focus = @(
            "Проверить annotation вручную и прочитать сырой ответ второй модели."
        )
        raw_response = $coderRaw
    }
}

$entityCount = @($annotation.observed_entities).Count
$dimensionCount = @($annotation.dimensions_and_designations).Count
$violationCount = @($annotation.possible_violations).Count
$schemaValidation = Test-AnnotationSchema -Annotation $annotation
$qualityFlags = @()
if (-not $schemaValidation.valid) {
    $qualityFlags += "annotation_schema_validation_failed"
}
if ($entityCount -lt 6) {
    $qualityFlags += "too_few_observed_entities"
}
if ($parseFailures.Count) {
    $qualityFlags += "vision_json_parse_failure"
}
if ($secondModelParseFailure) {
    $qualityFlags += "second_model_json_parse_failure"
}
if (
    [double]$secondModelReview.consistency_score -eq 0 -and
    @($secondModelReview.issues) -contains "structural or logical problems"
) {
    $qualityFlags += "second_model_placeholder_review"
}
if ([double]$secondModelReview.consistency_score -lt 0.6) {
    $qualityFlags += "second_model_low_consistency"
}
$viewCount = @($annotation.drawing_summary.views).Count
$violationText = (
    @($annotation.possible_violations | ForEach-Object {
        "{0} {1} {2}" -f $_.category, $_.description, $_.evidence
    }) -join " "
).ToLowerInvariant()
if (
    $viewCount -ge 3 -and
    $violationText -match 'missing views|no visible mechanical drawings|no views'
) {
    $qualityFlags += "contradictory_missing_views_claim"
}
$genericDimensionClaims = @($annotation.possible_violations | Where-Object {
    $text = ("{0} {1}" -f $_.description, $_.evidence).ToLowerInvariant()
    $text -match 'may vary|may need|not consistent|not uniformly' -and
    $text -notmatch '\d'
}).Count
if ($genericDimensionClaims -ge 2) {
    $qualityFlags += "generic_dimension_violation_claims"
}
$coordinateOnlyEvidence = @($annotation.possible_violations | Where-Object {
    $evidence = ([string]$_.evidence).Trim()
    $evidence -match '^[\[\{]\s*\d+(\s*,\s*\d+){3}\s*[\]\}]$'
}).Count
if ($coordinateOnlyEvidence -gt 0) {
    $qualityFlags += "coordinate_only_violation_evidence"
}
$unsupportedMissingDimensionClaims = @($annotation.possible_violations | Where-Object {
    $claim = ("{0} {1}" -f $_.category, $_.description).ToLowerInvariant()
    $claim -match 'missing dimension|lacks dimension|lacks specific dimension|no (numerical |visible )?dimension' -and
    -not $_.standard_reference
}).Count
if ($unsupportedMissingDimensionClaims -gt 0) {
    $qualityFlags += "unsupported_missing_dimension_claim"
}
$nonViolationCandidates = @($annotation.possible_violations | Where-Object {
    $claim = ("{0} {1}" -f $_.category, $_.description).ToLowerInvariant()
    $claim -match 'consistent with standard|appears correct|no violation|compliant'
}).Count
if ($nonViolationCandidates -gt 0) {
    $qualityFlags += "non_violation_in_violation_list"
}
$unsupportedMaterialClaims = @($annotation.possible_violations | Where-Object {
    $claim = ("{0} {1} {2}" -f $_.category, $_.description, $_.evidence).ToLowerInvariant()
    $claim -match 'material compatibility|material incompatib|may not be suitable' -and
    -not $_.standard_reference
}).Count
if ($unsupportedMaterialClaims -gt 0) {
    $qualityFlags += "unsupported_material_compatibility_claim"
}
$unsupportedRequiredViewClaims = @($annotation.possible_violations | Where-Object {
    $claim = ("{0} {1} {2}" -f $_.category, $_.description, $_.evidence).ToLowerInvariant()
    $claim -match 'lacks a top view|missing top view|lacks.*exploded|missing.*exploded' -and
    -not $_.standard_reference
}).Count
if ($unsupportedRequiredViewClaims -gt 0) {
    $qualityFlags += "unsupported_required_view_claim"
}
$missingStandardReferenceClaims = @($annotation.possible_violations | Where-Object {
    $claim = ("{0} {1}" -f $_.category, $_.description).ToLowerInvariant()
    $claim -match 'no specific standard reference|standard reference is not provided' -and
    -not $_.standard_reference
}).Count
if ($missingStandardReferenceClaims -gt 0) {
    $qualityFlags += "missing_reference_presented_as_violation"
}
if (
    $DocumentClass -in @("reference_cutaway", "schematic") -and
    $violationCount -gt 0
) {
    $qualityFlags += "non_normative_document_violation_claims"
}
$annotationText = $annotation | ConvertTo-Json -Depth 20
if ($annotation.drawing_summary.complexity -in @("low", "medium") -and (Get-Item $incomingPath).Length -gt 100KB) {
    $qualityFlags += "complexity_requires_review"
}
if (@($annotation.possible_violations | Where-Object {
    [double]$_.confidence -ge 0.8 -and -not $_.evidence
}).Count -gt 0) {
    $qualityFlags += "high_confidence_without_evidence"
}

$observationFlagNames = @(
    "too_few_observed_entities",
    "vision_json_parse_failure",
    "possible_mojibake",
    "complexity_requires_review",
    "annotation_schema_validation_failed"
)
$violationFlagNames = @(
    "second_model_json_parse_failure",
    "second_model_placeholder_review",
    "second_model_low_consistency",
    "contradictory_missing_views_claim",
    "generic_dimension_violation_claims",
    "coordinate_only_violation_evidence",
    "unsupported_missing_dimension_claim",
    "non_violation_in_violation_list",
    "unsupported_material_compatibility_claim",
    "unsupported_required_view_claim",
    "missing_reference_presented_as_violation",
    "non_normative_document_violation_claims",
    "high_confidence_without_evidence"
)
$observationFlags = @($qualityFlags | Where-Object { $_ -in $observationFlagNames })
$violationFlags = @($qualityFlags | Where-Object { $_ -in $violationFlagNames })
$otherFlags = @($qualityFlags | Where-Object {
    $_ -notin $observationFlagNames -and $_ -notin $violationFlagNames
})
$observationStatus = if ($observationFlags.Count -or $otherFlags.Count) {
    "needs_revision"
} else {
    "ready_for_human_review"
}
$violationStatus = if (-not $violationCount) {
    "no_candidates"
} elseif ($violationFlags.Count -or $otherFlags.Count) {
    "needs_revision"
} else {
    "ready_for_human_review"
}
$qualityStatus = if ($qualityFlags.Count) { "needs_revision" } else { "ready_for_human_review" }

$createdAt = (Get-Date).ToUniversalTime().ToString("o")
$reportId = "$SampleId-report"
$drawingId = "$SampleId-drawing-001"
$normalizedEntities = @()
for ($index = 0; $index -lt $entities.Count; $index++) {
    $item = $entities[$index]
    $rowNumber = "{0:D3}" -f ($index + 1)
    $normalizedEntities += [ordered]@{
        id = "$SampleId-entity-$rowNumber"
        report_id = $reportId
        name = [string]$item.entity
        evidence = [string]$item.evidence
        location = [string]$item.location
        confidence = [double]$item.confidence
    }
}
$normalizedDimensions = @()
for ($index = 0; $index -lt $dimensions.Count; $index++) {
    $item = $dimensions[$index]
    $rowNumber = "{0:D3}" -f ($index + 1)
    $normalizedDimensions += [ordered]@{
        id = "$SampleId-dimension-$rowNumber"
        report_id = $reportId
        text = [string]$item.text
        location = [string]$item.location
        confidence = [double]$item.confidence
    }
}
$normalizedIssues = @()
for ($index = 0; $index -lt $violations.Count; $index++) {
    $item = $violations[$index]
    $rowNumber = "{0:D3}" -f ($index + 1)
    $normalizedIssues += [ordered]@{
        id = "$SampleId-issue-$rowNumber"
        report_id = $reportId
        category = [string]$item.category
        description = [string]$item.description
        evidence = [string]$item.evidence
        severity = [string]$item.severity
        confidence = [double]$item.confidence
        standard_reference = [ordered]@{
            standard_code = [string]$item.standard_reference.standard_code
            title = [string]$item.standard_reference.title
            source_url = [string]$item.standard_reference.source_url
            local_source_path = [string]$item.standard_reference.local_source_path
            local_source_sha256 = [string]$item.standard_reference.local_source_sha256
            evidence_status = [string]$item.standard_reference.evidence_status
            clause_number = if ($item.standard_reference.clause_number) {
                [string]$item.standard_reference.clause_number
            } else {
                $null
            }
            source_quote_short = if ($item.standard_reference.source_quote_short) {
                [string]$item.standard_reference.source_quote_short
            } else {
                $null
            }
        }
        human_review_required = $true
    }
}
$normalizedUncertainties = @()
for ($index = 0; $index -lt $uncertainties.Count; $index++) {
    $rowNumber = "{0:D3}" -f ($index + 1)
    $normalizedUncertainties += [ordered]@{
        id = "$SampleId-uncertainty-$rowNumber"
        report_id = $reportId
        text = [string]$uncertainties[$index]
    }
}

$result = [ordered]@{
    schema_version = "2.0"
    reports = @(
        [ordered]@{
            id = $reportId
            sample_id = $SampleId
            source_file_name = [IO.Path]::GetFileName($source)
            source_url = $SourceUrl
            document_class = $DocumentClass
            status = "human_review_required"
            created_at = $createdAt
        }
    )
    drawings = @(
        [ordered]@{
            id = $drawingId
            report_id = $reportId
            drawing_type = [string]$annotation.drawing_summary.drawing_type
            subject = [string]$annotation.drawing_summary.subject
            complexity = [string]$annotation.drawing_summary.complexity
        }
    )
    entities = $normalizedEntities
    dimensions = $normalizedDimensions
    issues = $normalizedIssues
    uncertainties = $normalizedUncertainties
    provenance = [ordered]@{
        dataset_file = "incoming/$incomingName"
        sha256 = $sha256
        license = $License
        attribution = $Attribution
        preprocessing = $Preprocessing
    }
    pipeline = [ordered]@{
        vision_model = "qwen2.5vl:7b"
        normalizer_model = "qwen2.5-coder:7b"
        local_only = $true
    }
    second_model_review = $secondModelReview
    quality_gate = [ordered]@{
        status = $qualityStatus
        flags = $qualityFlags
        observation_status = $observationStatus
        observation_flags = $observationFlags
        violation_status = $violationStatus
        violation_flags = $violationFlags
        schema_valid = $schemaValidation.valid
        schema_errors = @($schemaValidation.errors)
        entity_count = $entityCount
        dimension_count = $dimensionCount
        violation_count = $violationCount
    }
    review = [ordered]@{
        reviewer = $null
        reviewed_at = $null
        decision = "pending"
        notes = ""
    }
    artifacts = [ordered]@{
        vision_response = "logs/$SampleId.vision-api.json"
        coder_response = "logs/$SampleId.coder.txt"
        vision_tiles = if ($tiles.Count) { "logs/$SampleId.tiles" } else { $null }
    }
}

$resultPath = Join-Path $pendingRoot "$SampleId.json"
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding utf8

$manifest = [ordered]@{
    sample_id = $SampleId
    result = "pending_review/$SampleId.json"
    source_sha256 = $sha256
    source_url = $SourceUrl
    license = $License
    created_at = $result.created_at
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath (Join-Path $manifestsRoot "$SampleId.json") `
    -Encoding utf8

Write-Host "TRAINING_JSON=$resultPath"
Write-Host "VISION_MODEL=qwen2.5vl:7b"
Write-Host "NORMALIZER_MODEL=qwen2.5-coder:7b"
