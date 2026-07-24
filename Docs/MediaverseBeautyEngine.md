# Mediaverse Beauty Engine

## Purpose

This document is the implementation and training specification for a proprietary,
on-device Mediaverse beauty and face-effects engine. The goal is a result comparable
to leading social-camera products while preserving identity, facial hair, pores,
eyes, lips, hair, clothing, and background.

The engine must:

- show the same effect in editor preview and final render;
- work for photos, recorded video, imported video, and camera preview;
- remain temporally stable during motion, occlusion, and expression changes;
- keep Beauty `0` pixel-identical to the input;
- provide a clearly visible but credible Beauty `100`;
- run completely on-device after the models are bundled;
- use models owned and trained for Mediaverse rather than a hosted generative model;
- degrade safely to the existing Core Image pipeline when a model is unavailable.

The current reference image pair is an acceptance target, not a sufficient training
dataset. A production model needs diverse, licensed training data.

## What the current implementation provides

The existing implementation should remain as the integration foundation:

- `StoryBeautySettings` is the versioned user-facing control contract.
- `StoryTimelineEditor` persists preview edits and supports undo.
- `StoryEditorPreviewView` exposes master and advanced controls.
- `StoryRenderEngine` applies effects to stills and video.
- Vision landmarks locate facial features.
- `FaceParser.mlpackage` produces a semantic skin mask.
- adaptive skin detection provides an offline fallback.
- Core Image provides the current smoothing and enhancement fallback.
- tests already enforce zero-intensity identity, Codable compatibility, preview
  persistence, and a non-empty fallback result.

The current limitation is not control strength. It is that generic blur, denoise,
sharpen, contrast, and color operations cannot distinguish wrinkles, blemishes,
pores, under-eye shadows, facial hair, and identity-critical edges well enough.

## Product behavior

### Controls

The existing controls map onto the learned engine as follows:

| UI control | Learned operation | Protected content |
|---|---|---|
| Beauty | coordinated preset curve across all heads | identity and background |
| Smooth | transient blemish removal and texture equalization | pores, beard, edges |
| Wrinkles | wrinkle probability reduction and local reconstruction | expression shape |
| Glow | low-frequency luminance and chroma refinement | highlights and skin tone |
| Clarity | face-only detail reconstruction | noise and compression artifacts |
| Tone | bounded, skin-only chroma correction | natural complexion |
| Brightness | exposure correction inside semantic face regions | highlights |
| Eyes | sclera cleanup, iris/eyelash detail preservation | iris color and geometry |
| Under eye | shadow and bag attenuation | eyelids and eye shape |
| Teeth | tooth-only neutralization | lips, gums, tooth geometry |

Beauty `100` is a coordinated studio-retouch preset, not simply every control at
its maximum. Independent controls remain available after applying the preset.

### Strength semantics

Every learned head predicts a residual or a restored target. Strength is applied by
interpolating from the original:

```text
output = original + controlCurve(strength) * confidence * semanticMask * residual
```

This guarantees an exact zero state, gives continuous control, and prevents a model
from changing pixels outside its intended region. Control curves should be perceptual
S-curves, with conservative movement from 0–40 and clearly visible movement from
60–100.

## Model architecture

### Recommended production topology

Use a shared lightweight encoder with separate, conditional decoder heads:

1. **Clear Skin head** — removes temporary blemishes and uneven micro-texture.
2. **Wrinkle head** — reduces wrinkles while reconstructing plausible surrounding
   skin texture.
3. **Under-Eye head** — reduces dark circles and bags without changing eye geometry.
4. **Tone/Glow head** — predicts low-frequency luminance and chroma corrections.
5. **Detail head** — restores pores and identity-bearing high-frequency detail.
6. **Feature head** — bounded eye and teeth corrections.

The network receives:

- linearized RGB face crop;
- semantic maps for skin, beard, hair, eyes, brows, lips, teeth, and background;
- landmark/mesh heatmaps;
- per-control strength vector;
- optional previous-frame features and motion confidence for video.

The network returns:

- RGB residual at face-crop resolution;
- per-head confidence maps;
- refined semantic alpha;
- restored high-frequency detail;
- optional recurrent feature state for video.

The output is composited into the original full-resolution frame. It must never
generate the whole frame.

### Multi-resolution design

Separate the problem by spatial frequency:

- the low-frequency branch corrects illumination, tone, redness, and under-eye shade;
- the middle-frequency branch handles wrinkles and blemishes;
- the high-frequency branch restores pores, fine hair, eyelashes, beard texture,
  and edge detail;
- a Laplacian-pyramid fusion module combines the branches.

This is the essential difference between professional retouching and blurring:
undesired structure is reduced while desired texture is put back.

### Preview and export variants

Train or distill two compatible variants:

| Variant | Input crop | Target runtime | Purpose |
|---|---:|---:|---|
| Live | 256–320 px | under 12 ms model time on target device | camera/editor video |
| Render | 512–768 px | under 45 ms per frame | still and final export |

Both variants must share output semantics and control calibration. The Render model
may use a larger detail head but must not create a visibly different look.

## Training data

### Required licensed dataset

Build a consented, rights-cleared dataset with:

- paired before/after professional retouches;
- clean captures plus synthetic degradations;
- still-image sequences and videos for temporal supervision;
- wide variation in skin tone, age, sex, face shape, facial hair, makeup, lighting,
  camera quality, compression, pose, expression, and occlusion;
- hard cases: glasses, bangs, masks, hands over the face, profiles, multiple faces,
  specular highlights, acne, scars, freckles, tattoos, and strong shadows.

Initial useful scale:

- 25,000–50,000 licensed before/after still pairs;
- 2,000+ short, high-frame-rate identity-consistent clips;
- at least 1,000 manually reviewed examples per critical demographic and hard-case
  bucket;
- a locked validation set containing no identity seen during training.

Do not scrape private faces or train on unlicensed social-media images.

### Retouching protocol

Professional retouchers receive a strict guide:

- preserve face geometry and identity;
- remove temporary blemishes but preserve permanent identity marks unless separately
  annotated;
- reduce, not erase, wrinkles at the natural target level;
- preserve pores, beard, eyebrows, lashes, and hair;
- avoid global whitening or skin-tone normalization;
- keep background and clothing pixel-identical;
- deliver layered adjustments where possible: clear skin, wrinkle, under-eye,
  tone/glow, eyes, and teeth.

Layered targets are substantially more valuable than only a flattened “after”
image because they teach independent controls.

### Annotations

Store:

- dense semantic face labels;
- 2D mesh/landmarks and visibility;
- wrinkle, blemish, under-eye, teeth, and facial-hair masks;
- optical flow and occlusion confidence for video pairs;
- capture metadata when consent permits;
- retouch strength and retoucher intent;
- quality-review status and rejection reason.

Use a versioned manifest with content hashes so every released model can be traced
to its exact data and annotation versions.

### Synthetic curriculum

Before fine-tuning on expert pairs, pretrain with reversible degradations:

- localized acne/blemish overlays;
- physically plausible melanin/haemoglobin color perturbations;
- wrinkle displacement and shaded line patterns aligned to facial anatomy;
- under-eye shadow gradients;
- sensor noise, sharpening halos, JPEG artifacts, and low-light chroma noise;
- uneven lighting and bounded redness;
- motion blur and compression changes across video frames.

Synthetic examples teach localization and control. Expert pairs teach aesthetic
judgment and realism.

## Losses and training stages

### Spatial losses

Use a weighted objective:

```text
L = L_reconstruction
  + L_perceptual
  + L_laplacian
  + L_texture
  + L_semantic_boundary
  + L_feature_identity
  + L_background_identity
  + L_control_monotonicity
  + L_temporal
```

- **Reconstruction:** masked Charbonnier/L1 against the expert target.
- **Perceptual:** feature-space similarity at several resolutions.
- **Laplacian/frequency:** match low, middle, and high-frequency target bands.
- **Texture:** preserve pore-scale statistics and gradients in clean skin regions.
- **Semantic boundary:** prevent halos and leakage at hair, beard, eyes, lips, and jaw.
- **Feature identity:** keep landmark geometry and face-recognition embedding stable.
- **Background identity:** heavily penalize any change outside the allowed masks.
- **Control monotonicity:** stronger controls must produce a gradual, directionally
  consistent result without discontinuities.
- **Temporal:** warp adjacent outputs with flow, ignore occluded pixels, and penalize
  flicker in both residuals and confidence masks.

An adversarial loss may be introduced late and at low weight for texture realism.
It must never dominate reconstruction or identity losses.

### Curriculum

1. Train semantic refinement and confidence estimation.
2. Train each decoder head separately on its layered target.
3. Train the shared conditional model with frozen semantic inputs.
4. Fine-tune all heads jointly for interaction quality.
5. Add video clips and temporal losses.
6. Distill and quantize the Live model from the Render teacher.
7. Calibrate UI control curves against a reviewed perceptual set.
8. Lock a model candidate and run fairness, performance, and regression gates.

## iOS runtime architecture

### Frame pipeline

```text
Original frame
  -> orientation/color normalization
  -> Vision face tracking and landmarks
  -> semantic parsing/refinement
  -> aligned face crop and conditioning maps
  -> Mediaverse Beauty Core ML model
  -> residual/confidence/alpha outputs
  -> full-resolution frequency-aware compositing
  -> creative filters, stickers, text, and overlays
  -> preview or export
```

Beauty should run before creative color filters and before stickers/overlays.
Otherwise the model may retouch a sticker or learn the wrong color distribution.

### Proposed code boundaries

- `StoryFaceAnalyzer`: owns landmarks, tracking, semantic maps, and face IDs.
- `StoryBeautyModel`: protocol for Live, Render, and fallback implementations.
- `StoryBeautyRequest`: crop, masks, landmarks, controls, timestamp, and prior state.
- `StoryBeautyResult`: residuals, confidence, refined alpha, and next temporal state.
- `StoryBeautyCompositor`: full-resolution, color-managed blending and detail fusion.
- `StoryBeautySession`: per-clip/per-face state, scheduling, caching, and cancellation.
- `StoryBeautyDiagnostics`: opt-in timing, fallback reason, model version, and mask
  coverage without storing face imagery.

`StoryCoreImageEffects.faceAwareBeauty` remains the compatibility entry point during
migration, then delegates to `StoryBeautySession`.

### Concurrency and caching

- one serial state machine per visible face;
- Vision and parsing off the main thread;
- Core ML with `.all` compute units and a tested Neural Engine path;
- reuse pixel buffers and `CIContext`;
- cache analysis by asset ID, timestamp bucket, orientation, crop transform, and
  parser/model version;
- discard stale results when a slider changes rapidly;
- render with deterministic settings and never reuse preview-resolution residuals
  for export.

### Video stability

- assign stable face IDs and keep one temporal state per face;
- analyze keyframes, then propagate landmarks/masks between them;
- reset state on cuts, tracking loss, large pose change, or seek;
- use forward/backward flow consistency to reject occluded pixels;
- smooth controls and alpha, not raw output frames;
- never carry state between different clips or people;
- export sequentially within each clip to reproduce temporal state deterministically.

For seek/scrub, warm the model from the nearest cached keyframe. If no warm state is
available, render the target frame spatially and blend temporal state in over the
next few frames.

### Multiple faces

Default behavior applies the preset independently to all confidently tracked faces.
Each face uses its own crop, semantic mask, and temporal state. Overlapping results
are combined by confidence, not draw order. Low-confidence or tiny faces remain
unchanged.

## Core ML delivery

- export from the owned training pipeline through a reproducible conversion script;
- use fixed, documented image normalization and color space;
- validate PyTorch and Core ML outputs on a golden tensor set;
- prefer ML Program with flexible batch disabled for predictable mobile latency;
- test FP16 first, then mixed/int8 quantization only if perceptual gates pass;
- bundle model metadata: semantic version, git revision, dataset manifest, input
  contract, output contract, minimum app version, and checksum;
- sign off Live and Render models as a matched pair;
- keep the existing Core Image path as a kill-switch fallback.

Model downloads may be added later, but the first production version should bundle
the model so Beauty never silently disappears due to network state.

## Quality and QA gates

### Golden visual set

Build a version-controlled test manifest referencing protected test assets outside
the public repository. It must include:

- the supplied original/reference case;
- every skin-tone and age bucket;
- facial hair, glasses, makeup, profiles, motion, occlusion, and multiple faces;
- still, camera, imported video, editor preview, and final-render paths.

Review a contact sheet at strengths 0, 25, 50, 75, and 100 for every release.

### Automated invariants

- Beauty `0` is byte-identical to the original.
- Background/outside-mask delta remains below the strict threshold.
- No NaN, empty output, crop mismatch, or orientation change.
- Face embedding drift stays below the identity threshold.
- Landmark geometry does not move for retouch-only controls.
- Changes grow monotonically with control strength.
- Beard, eyebrows, eyes, lips, and hair pass preservation thresholds.
- Preview and Render variants meet a bounded perceptual-difference target.
- Adjacent-frame residual warp error stays below the flicker threshold.
- A failed model or parser produces the tested fallback, never an unedited silent
  success unless Beauty is zero.

### Performance budgets

Measure on the oldest supported and current representative devices:

- p50/p95 frame time for one and two faces;
- dropped preview frames;
- peak memory and pixel-buffer churn;
- thermal state after a three-minute camera session;
- export time and energy;
- first-use model load latency;
- cancellation latency while scrubbing and changing controls.

Release gates should be device-specific. If the Live model misses its budget, reduce
analysis cadence or crop resolution while continuing to render the current stable
residual; do not block the editor.

### Human evaluation

Use blinded A/B review:

- original vs Mediaverse;
- Mediaverse candidate vs current release;
- Live preview vs final Render;
- candidate vs the agreed visual reference.

Reviewers score naturalness, visible improvement, identity, texture, boundary
artifacts, facial-hair preservation, tone fairness, and video stability. Report
results by demographic and hard-case bucket rather than only as one average.

## Privacy, safety, and fairness

- process frames on-device by default;
- do not retain face crops or embeddings in diagnostics;
- require explicit consent for training submissions;
- provide deletion and dataset provenance processes;
- test that equal UI strength produces comparable perceived intensity across skin
  tones without pushing complexions toward one target;
- preserve scars, freckles, moles, and age characteristics by default unless the
  user explicitly selects a targeted control;
- label geometric face reshaping separately from retouching if introduced later;
- keep Beauty off by default for newly imported media unless product policy
  explicitly changes.

## Delivery plan

### Phase 0 — specification and benchmark

- freeze the original/reference acceptance pair;
- build the golden-set manifest and comparison renderer;
- record current quality and performance;
- finalize data rights and retouching guide.

Exit: repeatable baseline metrics and approved visual targets.

### Phase 1 — owned still-image prototype

- prepare the layered dataset;
- train semantic refinement plus Clear Skin and Detail heads;
- integrate a Render-only Core ML prototype behind a feature flag;
- validate identity, background protection, beards, and boundaries.

Exit: the agreed reference shows a substantial, natural improvement without the
black spots, oversharpening, halos, or waxy texture seen in earlier attempts.

### Phase 2 — complete retouch controls

- add Wrinkle, Under-Eye, Tone/Glow, and Feature heads;
- train joint interactions and calibrate the existing sliders;
- add preview/render parity tests and model metadata.

Exit: all current controls have independent, predictable, gradual effects.

### Phase 3 — real-time preview

- distill the Live model;
- implement buffer reuse, scheduling, cancellation, and adaptive cadence;
- test sustained thermal and frame-rate behavior.

Exit: fluid editor/camera preview on the oldest supported device.

### Phase 4 — temporally stable video

- train with video data and occlusion-aware temporal losses;
- add face-state lifecycle, seek warming, cut detection, and deterministic export;
- test transitions between capture, editor, and final render.

Exit: no visible mask swimming, flicker, stale face state, or preview/export jump.

### Phase 5 — semantic masks and creative effects

- add a dense face mesh and expression coefficients;
- expose a versioned mask/effect package format;
- support 2D/3D anchored assets, occlusion, deformation, and per-effect logic;
- add authoring validation and device capability tiers.

Exit: owned, server-configurable mask packages run safely across camera, editor,
playback, and export.

## Definition of done

The Beauty Engine is production-ready only when:

- the same controls produce the same intended look in camera, editor, and export;
- Beauty `100` is visibly close to the approved reference while remaining a
  photorealistic version of the same person;
- hair, beard, eyes, lips, clothing, and background are preserved;
- video remains stable through motion, expressions, occlusions, seeks, and cuts;
- all zero/fallback/backward-compatibility tests pass;
- performance and fairness gates pass on the supported device matrix;
- model, dataset, conversion, and app revisions are reproducible and auditable.

## Research foundation

- Xu et al., *Face Retouching with Diffusion Data Generation and Spectral
  Restorement*, ICCV 2025 — frequency selection/restoration, multi-resolution
  fusion, and a large paired retouching dataset.
- Velusamy et al., *FabSoften: Face Beautification via Dynamic Skin Smoothing,
  Guided Feathering, and Texture Restoration*, CVPR Workshops 2020 — real-time
  smoothing with high-frequency texture restoration.
- Liu et al., *Controllable and Gradual Facial Blemishes Retouching via
  Physics-Based Modelling*, 2024 — controllable blemish synthesis and
  melanin/haemoglobin-based color modeling.
- Kim et al., *Photorealistic Facial Wrinkles Removal*, 2022 — localized wrinkle
  segmentation and texture-consistent reconstruction.
- Baghbaderani et al., *Temporally-Consistent Video Semantic Segmentation with
  Bidirectional Occlusion-Guided Feature Propagation*, WACV 2024 — temporal
  propagation with occlusion handling.
- Snap Lens Studio Face Mesh and ML Retouch documentation — public evidence of
  dense face tracking and separately controlled clear-skin, wrinkle, and eye-bag
  retouch operations in a production social-camera stack.

