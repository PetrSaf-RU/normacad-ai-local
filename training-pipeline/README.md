# NormaCAD training data pipeline

Local, human-review-first dataset preparation for technical drawings.

The pipeline uses:

- `qwen2.5vl:7b` for visual observations;
- `qwen2.5-coder:7b` for a second consistency review;
- normalized JSON schema v2;
- deterministic IDs and `report_id` relations;
- quality gates that prevent automatic approval.

Copy this folder into a portable NormaCAD directory containing
`training-data/`, then run `prepare-training-sample.ps1`.

No generated report is moved to `approved` automatically.
