# Legacy AI JSON v2 adapter

This folder lets an older local NormaCAD/Qwen installation use the normalized
NormaCAD report schema v2 without changing or retraining model weights.

## Direct local analysis

Start Ollama, make sure the vision model is installed, then run:

```powershell
.\Invoke-LegacyAiWithV2Template.ps1 `
  -ImagePath "C:\drawings\engine.png" `
  -OutputJson ".\results\engine.json" `
  -SampleId "engine_001" `
  -SourceUrl "https://source.example/item" `
  -License "Public domain" `
  -Attribution "Archive and author"
```

The script sends `legacy-analysis-prompt.txt` to the old local model, stores its
original response beside the output as `*.legacy.json`, validates the essential
legacy fields, and converts them into:

- `reports`
- `drawings`
- `entities`
- `dimensions`
- `issues`
- `uncertainties`

All child rows contain `report_id`. IDs are deterministic. Every issue is
forced to `human_review_required=true`.

## Convert an existing old response

```powershell
.\Convert-LegacyAnalysisToV2.ps1 `
  -InputJson ".\old-response.json" `
  -OutputJson ".\normalized-response.json" `
  -SampleId "drawing_001" `
  -SourceFileName "drawing.png"
```

`legacy-analysis-template.json` describes the old model output expected by the
adapter. `normacad-report-v2.schema.json` describes the normalized output.

The adapter does not make old model observations legally or technically
verified. Every generated report remains pending human review.
