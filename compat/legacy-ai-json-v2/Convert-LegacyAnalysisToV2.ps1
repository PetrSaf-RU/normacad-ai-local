param(
    [Parameter(Mandatory = $true)]
    [string]$InputJson,
    [Parameter(Mandatory = $true)]
    [string]$OutputJson,
    [Parameter(Mandatory = $true)]
    [string]$SampleId,
    [string]$SourceFileName = "",
    [string]$SourceUrl = "",
    [string]$DocumentClass = "unknown",
    [string]$License = "",
    [string]$Attribution = "",
    [string]$VisionModel = "legacy-local-model",
    [string]$TextModel = "legacy-local-model"
)

$ErrorActionPreference = "Stop"

function Require-Value {
    param($Value, [string]$Name)
    if ($null -eq $Value -or ([string]$Value).Trim().Length -eq 0) {
        throw "Missing required legacy field: $Name"
    }
}

function Parse-Confidence {
    param($Value, [string]$Name)
    $number = 0.0
    if (-not [double]::TryParse(
        ([string]$Value),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    ) -or $number -lt 0 -or $number -gt 1) {
        throw "Invalid confidence at $Name"
    }
    return $number
}

$legacy = Get-Content -LiteralPath $InputJson -Raw -Encoding utf8 |
    ConvertFrom-Json
Require-Value $legacy.drawing_summary.drawing_type "drawing_summary.drawing_type"
Require-Value $legacy.drawing_summary.subject "drawing_summary.subject"
if ($legacy.drawing_summary.complexity -notin @("low", "medium", "high", "very_high")) {
    throw "Invalid drawing_summary.complexity"
}

$reportId = "$SampleId-report"
$entities = @()
$index = 0
foreach ($item in @($legacy.observed_entities)) {
    $index++
    Require-Value $item.entity "observed_entities[$index].entity"
    Require-Value $item.evidence "observed_entities[$index].evidence"
    Require-Value $item.location "observed_entities[$index].location"
    $entities += [ordered]@{
        id = "$SampleId-entity-$('{0:D3}' -f $index)"
        report_id = $reportId
        name = [string]$item.entity
        evidence = [string]$item.evidence
        location = [string]$item.location
        confidence = Parse-Confidence $item.confidence "observed_entities[$index]"
    }
}

$dimensions = @()
$index = 0
foreach ($item in @($legacy.dimensions_and_designations)) {
    $index++
    Require-Value $item.text "dimensions_and_designations[$index].text"
    Require-Value $item.location "dimensions_and_designations[$index].location"
    $dimensions += [ordered]@{
        id = "$SampleId-dimension-$('{0:D3}' -f $index)"
        report_id = $reportId
        text = [string]$item.text
        location = [string]$item.location
        confidence = Parse-Confidence $item.confidence "dimensions_and_designations[$index]"
    }
}

$issues = @()
$index = 0
foreach ($item in @($legacy.possible_violations)) {
    $index++
    foreach ($field in "category", "description", "evidence", "severity") {
        Require-Value $item.$field "possible_violations[$index].$field"
    }
    if ($item.severity -notin @("info", "warning", "error")) {
        throw "Invalid severity at possible_violations[$index]"
    }
    $issues += [ordered]@{
        id = "$SampleId-issue-$('{0:D3}' -f $index)"
        report_id = $reportId
        category = [string]$item.category
        description = [string]$item.description
        evidence = [string]$item.evidence
        severity = [string]$item.severity
        confidence = Parse-Confidence $item.confidence "possible_violations[$index]"
        human_review_required = $true
    }
}

$uncertainties = @()
$index = 0
foreach ($text in @($legacy.uncertainties)) {
    if (-not ([string]$text).Trim()) { continue }
    $index++
    $uncertainties += [ordered]@{
        id = "$SampleId-uncertainty-$('{0:D3}' -f $index)"
        report_id = $reportId
        text = [string]$text
    }
}

$result = [ordered]@{
    schema_version = "2.0"
    reports = @([ordered]@{
        id = $reportId
        sample_id = $SampleId
        source_file_name = $SourceFileName
        source_url = $SourceUrl
        document_class = $DocumentClass
        status = "human_review_required"
        created_at = (Get-Date).ToUniversalTime().ToString("o")
    })
    drawings = @([ordered]@{
        id = "$SampleId-drawing-001"
        report_id = $reportId
        drawing_type = [string]$legacy.drawing_summary.drawing_type
        subject = [string]$legacy.drawing_summary.subject
        complexity = [string]$legacy.drawing_summary.complexity
    })
    entities = $entities
    dimensions = $dimensions
    issues = $issues
    uncertainties = $uncertainties
    provenance = [ordered]@{
        license = $License
        attribution = $Attribution
        adapter = "legacy-ai-json-v2"
    }
    pipeline = [ordered]@{
        vision_model = $VisionModel
        normalizer_model = $TextModel
        local_only = $true
    }
    quality_gate = [ordered]@{
        status = "needs_human_review"
        flags = @("legacy_model_adapter")
        entity_count = $entities.Count
        dimension_count = $dimensions.Count
        violation_count = $issues.Count
    }
    review = [ordered]@{
        reviewer = $null
        reviewed_at = $null
        decision = "pending"
        notes = ""
    }
    artifacts = [ordered]@{
        legacy_response = (Resolve-Path -LiteralPath $InputJson).Path
    }
}

$parent = Split-Path -Parent $OutputJson
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$result | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $OutputJson -Encoding utf8
Write-Host "NORMALIZED_JSON=$(Resolve-Path -LiteralPath $OutputJson)"
