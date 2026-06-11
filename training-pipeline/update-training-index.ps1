$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$trainingRoot = Join-Path $root "training-data"
$indexRoot = Join-Path $trainingRoot "manifests"
$rows = @()

foreach ($statusDirectory in "pending_review", "approved", "rejected", "superseded") {
    $directory = Join-Path $trainingRoot $statusDirectory
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter *.json -File -ErrorAction SilentlyContinue) {
        try {
            $sample = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 |
                ConvertFrom-Json
            $isNormalized = [string]$sample.schema_version -eq "2.0"
            if ($isNormalized) {
                $report = @($sample.reports)[0]
                $drawing = @($sample.drawings)[0]
                $sampleId = [string]$report.sample_id
                $reviewStatus = [string]$report.status
                $subject = [string]$drawing.subject
                $complexity = [string]$drawing.complexity
                $entityTotal = @($sample.entities).Count
                $dimensionTotal = @($sample.dimensions).Count
                $violationTotal = @($sample.issues).Count
                $sourceUrl = [string]$report.source_url
                $license = [string]$sample.provenance.license
                $documentClass = [string]$report.document_class
                $preprocessing = [string]$sample.provenance.preprocessing
            } else {
                $sampleId = [string]$sample.sample_id
                $reviewStatus = [string]$sample.status
                $subject = [string]$sample.annotation.drawing_summary.subject
                $complexity = [string]$sample.annotation.drawing_summary.complexity
                $entityTotal = @($sample.annotation.observed_entities).Count
                $dimensionTotal = @($sample.annotation.dimensions_and_designations).Count
                $violationTotal = @($sample.annotation.possible_violations).Count
                $sourceUrl = [string]$sample.source.source_url
                $license = [string]$sample.source.license
                $documentClass = [string]$sample.source.document_class
                $preprocessing = [string]$sample.source.preprocessing
            }
            $qualityStatus = [string]$sample.quality_gate.status
            $qualityFlags = @($sample.quality_gate.flags)
            if (-not $qualityStatus) {
                $qualityStatus = "needs_revision"
                $qualityFlags += "legacy_sample_without_quality_gate"
            }
            $observationStatus = [string]$sample.quality_gate.observation_status
            $violationStatus = [string]$sample.quality_gate.violation_status
            if (-not $observationStatus -or -not $violationStatus) {
                $observationFlagNames = @(
                    "too_few_observed_entities",
                    "vision_json_parse_failure",
                    "possible_mojibake",
                    "complexity_requires_review",
                    "annotation_schema_validation_failed",
                    "legacy_sample_without_quality_gate"
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
                    "non_normative_document_violation_claims",
                    "high_confidence_without_evidence"
                )
                $legacyObservationFlags = @($qualityFlags | Where-Object {
                    $_ -in $observationFlagNames
                })
                $legacyViolationFlags = @($qualityFlags | Where-Object {
                    $_ -in $violationFlagNames
                })
                if (-not $observationStatus) {
                    $observationStatus = if ($legacyObservationFlags.Count) {
                        "needs_revision"
                    } else {
                        "ready_for_human_review"
                    }
                }
                if (-not $violationStatus) {
                    $violationStatus = if (-not $violationTotal) {
                        "no_candidates"
                    } elseif ($legacyViolationFlags.Count) {
                        "needs_revision"
                    } else {
                        "ready_for_human_review"
                    }
                }
            }
            $rows += [pscustomobject]@{
                sample_id = $sampleId
                status_directory = $statusDirectory
                review_status = $reviewStatus
                quality_status = $qualityStatus
                quality_flags = $qualityFlags -join "|"
                observation_status = $observationStatus
                violation_status = $violationStatus
                schema_valid = $sample.quality_gate.schema_valid
                subject = $subject
                complexity = $complexity
                entities = $entityTotal
                dimensions = $dimensionTotal
                violations = $violationTotal
                source_url = $sourceUrl
                license = $license
                document_class = $documentClass
                preprocessing = $preprocessing
                json_path = $file.FullName
            }
        } catch {
            $rows += [pscustomobject]@{
                sample_id = $file.BaseName
                status_directory = $statusDirectory
                review_status = "invalid_json"
                quality_status = "invalid_json"
                quality_flags = $_.Exception.Message
                observation_status = "invalid_json"
                violation_status = "invalid_json"
                schema_valid = $false
                subject = ""
                complexity = ""
                entities = 0
                dimensions = 0
                violations = 0
                source_url = ""
                license = ""
                document_class = ""
                preprocessing = ""
                json_path = $file.FullName
            }
        }
    }
}

$rows = @($rows | Sort-Object sample_id)
$rows | Export-Csv `
    -LiteralPath (Join-Path $indexRoot "training-index.csv") `
    -NoTypeInformation `
    -Encoding utf8
$rows | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $indexRoot "training-index.json") -Encoding utf8

Write-Host "INDEX_JSON=$(Join-Path $indexRoot 'training-index.json')"
Write-Host "INDEX_CSV=$(Join-Path $indexRoot 'training-index.csv')"
Write-Host "SAMPLES=$($rows.Count)"
