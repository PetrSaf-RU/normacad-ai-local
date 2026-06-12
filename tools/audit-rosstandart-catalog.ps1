param(
    [string]$Manifest = (Join-Path $PSScriptRoot "..\standards\catalog\eskd_manifest.csv"),
    [string]$Output = (Join-Path $PSScriptRoot "..\standards\catalog\rosstandart-audit.csv")
)

$ErrorActionPreference = "Continue"
$rows = @()
foreach ($entry in Import-Csv -LiteralPath $Manifest -Encoding utf8) {
    $statusCode = 0
    $errorText = ""
    try {
        $response = Invoke-WebRequest `
            -Uri $entry.SourceUrl `
            -UseBasicParsing `
            -TimeoutSec 45 `
            -Headers @{"User-Agent" = "NormaCAD-AI local standards audit"}
        $statusCode = [int]$response.StatusCode
    } catch {
        $errorText = $_.Exception.Message
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
    }

    $rows += [pscustomobject]@{
        code = $entry.Code
        source_url = $entry.SourceUrl
        expected_status = $entry.Status
        checked_at = (Get-Date).ToUniversalTime().ToString("o")
        http_status = $statusCode
        reachable = $statusCode -eq 200
        error = $errorText
    }
    Start-Sleep -Milliseconds 750
}

$rows | Export-Csv -LiteralPath $Output -NoTypeInformation -Encoding utf8
Write-Host "AUDIT=$Output"
Write-Host "REACHABLE=$(@($rows | Where-Object reachable).Count)"
Write-Host "TOTAL=$($rows.Count)"
