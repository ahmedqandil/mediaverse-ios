# Mediaverse Beauty Engine Training

This package is the owned model-development path for Mediaverse Beauty. It predicts
small, bounded corrections to the original face and cannot regenerate the whole
person or background.

It is intentionally not connected to the shipping iOS renderer until a trained model
passes the golden visual, identity, licensing, performance, and Core ML parity gates.

## Architecture

- eight semantic inputs: skin, beard, hair, eyes, brows, lips, teeth, background;
- eight independently trainable controls;
- shared mobile encoder;
- low-frequency correction branch for tone and illumination;
- high-frequency branch for blemish removal and texture restoration;
- residual, confidence, refined-mask, and detail outputs;
- exact identity at master strength zero;
- explicit background-change penalty.

## Environment

Use Python 3.11. The repository host's Python 3.14 is not the supported environment
for the current PyTorch and Core ML conversion toolchain.

```sh
cd ML/BeautyEngine
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Do not install research-only pretrained weights. Mediaverse model checkpoints must be
trained from commercially licensed data.

## Dataset contract

Each JSONL record contains:

- source and professionally retouched target;
- a stable, non-identifying `subject_id`;
- eight aligned semantic masks;
- the intended control strengths;
- split name;
- license and consent identifiers;
- explicit `commercial_training: true`.

The loader rejects records without affirmative commercial-training rights.
See `examples/manifest.jsonl` for the complete schema.

The source, target, and masks must be geometrically aligned. Identity splits are
mandatory: the same person must never occur across train, validation, and test.

Audit all splits together before training. This rejects the same identity appearing in
more than one split and optionally verifies every referenced file:

```sh
PYTHONPATH=. python -m beauty_engine.manifest \
  data/train.jsonl \
  --additional data/validation.jsonl data/test.jsonl \
  --check-files
```

## Train

```sh
PYTHONPATH=. python -m beauty_engine.train --config configs/render.yaml
PYTHONPATH=. python -m beauty_engine.train --config configs/live.yaml
```

Train the Render model first. Distill its accepted behavior into the smaller Live
architecture:

```sh
PYTHONPATH=. python -m beauty_engine.distill \
  --teacher checkpoints/render/best.pt \
  --student-config configs/live.yaml
```

Configuration weights
for external perceptual and identity losses default to zero until Mediaverse approves
commercially safe feature extractors.

The training objective includes exact zero-control reconstruction, control
monotonicity, protected-region preservation, and an occlusion-aware temporal primitive.
Video production training must supply adjacent frames plus optical flow and occlusion
masks; repeating still frames is only a pipeline smoke test, not temporal validation.

## Evaluate

The evaluator measures target PSNR, changed-pixel fraction, and background leakage:

```sh
PYTHONPATH=. python -m beauty_engine.evaluate \
  --source golden/original.png \
  --target golden/reference.png \
  --output reports/candidate.png \
  --skin-mask golden/skin.png
```

Automated metrics are necessary but not sufficient. Every candidate must also pass
blinded human review for naturalness, identity, skin texture, beard/hair preservation,
skin-tone fairness, and preview/export consistency.

## Export to Core ML

```sh
PYTHONPATH=. python -m beauty_engine.export_coreml \
  --checkpoint checkpoints/live/best.pt \
  --output exports/MediaverseBeautyLive.mlpackage
```

Export begins with FP16. Quantization is allowed only after the FP16 model passes
PyTorch/Core ML golden-tensor parity and real-device visual evaluation.

Run numerical parity:

```sh
PYTHONPATH=. python -m beauty_engine.parity \
  --checkpoint checkpoints/live/best.pt \
  --model exports/MediaverseBeautyLive.mlpackage
```

Create immutable provenance:

```sh
PYTHONPATH=. python -m beauty_engine.provenance \
  --checkpoint checkpoints/live/best.pt \
  --manifests data/train.jsonl data/validation.jsonl data/test.jsonl \
  --output reports/provenance.json
```

## Tests

With the Python 3.11 environment:

```sh
PYTHONPATH=. python -m unittest discover -s tests -v
```

The manifest tests use only the Python standard library and can run without installing
the ML stack by loading `beauty_engine/manifest.py` directly. The model tests require
PyTorch.

## Release gates

A checkpoint cannot enter the iOS app until it has:

1. a locked data manifest and rights report;
2. identity-disjoint validation and test results;
3. exact zero-strength identity;
4. bounded background and protected-feature deltas;
5. golden-reference contact sheets at strengths 0/25/50/75/100;
6. FP16 PyTorch/Core ML output parity;
7. device latency, memory, and thermal measurements;
8. demographic and hard-case review;
9. a model card with checkpoint hash, source revision, and dataset revision.

The final automated gate refuses promotion when required artifacts, validation/test
splits, file-backed dataset records, metrics, or Core ML parity are missing:

```sh
PYTHONPATH=. python -m beauty_engine.release_gate \
  --checkpoint checkpoints/live/best.pt \
  --coreml-model exports/MediaverseBeautyLive.mlpackage \
  --manifests data/train.jsonl data/validation.jsonl data/test.jsonl \
  --metrics reports/release-metrics.json \
  --model-card reports/model-card.md \
  --output reports/release-gate.json
```

Required metric keys are `zero_strength_max_delta`, `background_mean_delta`,
`protected_feature_mean_delta`, `coreml_max_delta`, and
`preview_export_mean_delta`. Passing this automated gate does not replace real-device
latency/thermal testing or blinded demographic and hard-case review.
