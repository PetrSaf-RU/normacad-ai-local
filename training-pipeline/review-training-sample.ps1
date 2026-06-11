param(
    [Parameter(Mandatory = $true)]
    [string]$SampleId,
    [Parameter(Mandatory = $true)]
    [ValidateSet("approve", "reject", "supersede")]
    [string]$Decision,
    [Parameter(Mandatory = $true)]
    [string]$Reviewer,
    [Parameter(Mandatory = $true)]
    [string]$Notes,
    [string]$SupersededBy = "",
    [switch]$AllowQualityOverride
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$trainingRoot = Join-Path $root "training-data"
$sourcePath = Join-Path $trainingRoot "pending_review\$SampleId.json"
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Pending sample was not found: $sourcePath"
}

$sample = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8 |
    ConvertFrom-Json
$qualityStatus = [string]$sample.quality_gate.status
if (
    $Decision -eq "approve" -and
    $qualityStatus -ne "ready_for_human_review" -and
    -not $AllowQualityOverride
) {
    throw "Sample quality is '$qualityStatus'. Fix it first or use -AllowQualityOverride with an explicit reviewer decision."
}
if ($Decision -eq "supersede" -and -not $SupersededBy) {
    throw "-SupersededBy is required for the supersede decision."
}

$destinationName = switch ($Decision) {
    "approve" { "approved" }
    "reject" { "rejected" }
    "supersede" { "superseded" }
}
$destinationDirectory = Join-Path $trainingRoot $destinationName
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

$newStatus = switch ($Decision) {
    "approve" { "approved" }
    "reject" { "rejected" }
    "supersede" { "superseded" }
}
if ([string]$sample.schema_version -eq "2.0") {
    $sample.reports[0].status = $newStatus
} else {
    $sample.status = $newStatus
}
$sample.review.reviewer = $Reviewer
$sample.review.reviewed_at = (Get-Date).ToUniversalTime().ToString("o")
$sample.review.decision = $Decision
$sample.review.notes = $Notes
if ($Decision -eq "supersede") {
    $sample.review | Add-Member `
        -NotePropertyName superseded_by `
        -NotePropertyValue $SupersededBy `
        -Force
}

$destinationPath = Join-Path $destinationDirectory "$SampleId.json"
$sample | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $destinationPath -Encoding utf8
Remove-Item -LiteralPath $sourcePath -Force

& (Join-Path $root "scripts\update-training-index.ps1")
Write-Host "REVIEWED_JSON=$destinationPath"
Write-Host "DECISION=$Decision"
