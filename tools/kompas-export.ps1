param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Split-Path -Parent $SourcePath) "normacad-export"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$sourceFull = (Resolve-Path -LiteralPath $SourcePath).Path
$baseName = [IO.Path]::GetFileNameWithoutExtension($sourceFull)
$pdfPath = Join-Path $OutDir ($baseName + ".pdf")

try {
    try {
        $kompas = [Runtime.InteropServices.Marshal]::GetActiveObject("Kompas.Application.7")
    } catch {
        $kompas = New-Object -ComObject "Kompas.Application.7"
    }

    $kompas.Visible = $false
    $doc = $kompas.Documents.Open($sourceFull, $false)
    $pdfParams = $doc.PDFExportParam
    $pdfParams.Init()
    $pdfParams.ColorOutput = $true
    $pdfParams.EmbedFonts = $true
    $pdfParams.MultiPage = $true
    $pdfParams.Resolution = 600

    $ok = $doc.SaveAsToPDF($pdfPath, $pdfParams)
    $doc.Close(0)
    if (-not $ok) {
        throw "KOMPAS API returned false while exporting PDF."
    }

    Write-Host $pdfPath
} catch {
    Write-Error "Не удалось экспортировать через KOMPAS API. Откройте файл в КОМПАС-3D и экспортируйте в PDF/DXF вручную, затем импортируйте результат в standards/inbox. Детали: $($_.Exception.Message)"
}
