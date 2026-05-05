# H.264 verification manifest harness

This directory contains the repo-local verification manifest created from the t_f29fe210 feature-complete verification contract.

Files:

- `h264_full_matrix.json` — manifest of the existing 21 smoke cases, pending feature lanes, runtime tier policy, negative tests, public-decoder gates, and RTL byte-ownership audit policy.
- `../scripts/run_h264_verify_manifest.py` — conservative runner that selects manifest entries, refuses blocked long tiers (T2/T3), emits machine-readable JSON summaries, and runs negative/audit hooks.

Safe examples:

```bash
python3 scripts/run_h264_verify_manifest.py --validate-manifest --list
python3 scripts/run_h264_verify_manifest.py --dry-run --case smoke_8b_420 --case smoke_8b_420_cabac_pskip
python3 scripts/run_h264_verify_manifest.py --negative NEG-ERRORPAT-001 --negative NEG-MALFORMED-001 --audit-only
python3 scripts/run_h264_verify_manifest.py --case smoke_8b_420 --case smoke_8b_420_cabac_pskip --case smoke_8b_420_bdirect
```

Expected-fail example:

```bash
python3 scripts/run_h264_verify_manifest.py --negative NEG-REPAIR-001
```

Deliberate guardrail:

- T2 (`1280x720 @ 24f`) and T3 (`1280x720 @ 240f/10s BBB`) entries can be listed, but the runner returns `BLOCKED` and will not execute them while the manifest says those tiers are blocked.
- Pending feature lanes are not counted as PASS. They must register explicit fixture commands before they can become runnable.
- Negative fixtures are harness tests; they must not rewrite or repair RTL-emitted bytes.
- `NEG-REPAIR-001` stages a synthetic poisoned fixture under `output/negative_fixtures/` and should return `RED_EXPECTED_FAIL` when the no-repair audit catches the injected repair line.
- Packaging-only MP4 wrapping is allowed only when it preserves the RTL Annex B payload; final H.264 syntax remains RTL-owned.
