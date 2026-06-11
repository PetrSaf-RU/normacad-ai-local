param(
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$trainingRoot = Join-Path $root "training-data"
$backupRoot = Join-Path $trainingRoot (
    "schema-v1-backup-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
)
$converted = 0
$skipped = 0

function New-NormalizedRows {
    param(
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string]$SampleId,
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $rows = @()
    $index = 0
    foreach ($item in @($Items)) {
        $index++
        $id = "$SampleId-$Kind-$('{0:D3}' -f $index)"
        switch ($Kind) {
            "entity" {
                $rows += [ordered]@{
                    id = $id
                    report_id = $ReportId
                    name = [string]$item.entity
                    evidence = [string]$item.evidence
                    location = [string]$item.location
                    confidence = [double]$item.confidence
                }
            }
            "dimension" {
                $rows += [ordered]@{
                    id = $id
                    report_id = $ReportId
                    text = [string]$item.text
                    location = [string]$item.location
                    confidence = [double]$item.confidence
                }
            }
            "issue" {
                $rows += [ordered]@{
                    id = $id
                    report_id = $ReportId
                    category = [string]$item.category
                    description = [string]$item.description
                    evidence = [string]$item.evidence
                    severity = [string]$item.severity
                    confidence = [double]$item.confidence
                    human_review_required = $true
                }
            }
            "uncertainty" {
                $rows += [ordered]@{
                    id = $id
                    report_id = $ReportId
                    text = [string]$item
                }
            }
        }
    }
    return @($rows)
}

foreach ($statusDirectory in "pending_review", "approved", "rejected", "superseded") {
    $directory = Join-Path $trainingRoot $statusDirectory
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter *.json -File -ErrorAction SilentlyContinue) {
        $sample = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 |
            ConvertFrom-Json
        if ([string]$sample.schema_version -eq "2.0") {
            $skipped++
            continue
        }

        if (-not $SkipBackup) {
            $backupDirectory = Join-Path $backupRoot $statusDirectory
            New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $backupDirectory -Force
        }

        $sampleId = [string]$sample.sample_id
        $reportId = "$sampleId-report"
        $reviewStatus = if ($sample.status) {
            [string]$sample.status
        } else {
            "human_review_required"
        }
        $normalized = [ordered]@{
            schema_version = "2.0"
            reports = @(
                [ordered]@{
                    id = $reportId
                    sample_id = $sampleId
                    source_file_name = [string]$sample.source.original_file_name
                    source_url = [string]$sample.source.source_url
                    document_class = [string]$sample.source.document_class
                    status = $reviewStatus
                    created_at = [string]$sample.created_at
                }
            )
            drawings = @(
                [ordered]@{
                    id = "$sampleId-drawing-001"
                    report_id = $reportId
                    drawing_type = [string]$sample.annotation.drawing_summary.drawing_type
                    subject = [string]$sample.annotation.drawing_summary.subject
                    complexity = [string]$sample.annotation.drawing_summary.complexity
                }
            )
            entities = New-NormalizedRows `
                -Items $sample.annotation.observed_entities `
                -SampleId $sampleId `
                -ReportId $reportId `
                -Kind "entity"
            dimensions = New-NormalizedRows `
                -Items $sample.annotation.dimensions_and_designations `
                -SampleId $sampleId `
                -ReportId $reportId `
                -Kind "dimension"
            issues = New-NormalizedRows `
                -Items $sample.annotation.possible_violations `
                -SampleId $sampleId `
                -ReportId $reportId `
                -Kind "issue"
            uncertainties = New-NormalizedRows `
                -Items $sample.annotation.uncertainties `
                -SampleId $sampleId `
                -ReportId $reportId `
                -Kind "uncertainty"
            provenance = [ordered]@{
                dataset_file = [string]$sample.source.dataset_file
                sha256 = [string]$sample.source.sha256
                license = [string]$sample.source.license
                attribution = [string]$sample.source.attribution
                preprocessing = [string]$sample.source.preprocessing
            }
            pipeline = $sample.pipeline
            second_model_review = $sample.second_model_review
            quality_gate = $sample.quality_gate
            review = $sample.review
            artifacts = $sample.artifacts
        }
        $normalized | ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $file.FullName -Encoding utf8
        $converted++
    }
}

& (Join-Path $root "scripts\update-training-index.ps1")
Write-Host "CONVERTED=$converted"
Write-Host "SKIPPED=$skipped"
if (-not $SkipBackup) {
    Write-Host "BACKUP=$backupRoot"
}
