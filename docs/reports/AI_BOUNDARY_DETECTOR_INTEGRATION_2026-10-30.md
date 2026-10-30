# Boundary detector integration evidence — 2026-10-30

## Integrated offline detector

The app bundles the upstream `DocQuadNet-256` ORT-format model at
`assets/models/docquadnet256_trained_opset17.ort` (13,404,960 bytes).
The upstream MakeACopy checkout inspected was commit
`612525350d7433accf6a00feeacbe41891aa1e4a`; its README calls the exported
inference model Apache-2.0 and says training data/checkpoints are not shipped.
That is the upstream maintainer's declaration, not an independent dataset-rights
opinion. Dataset terms remain those of the respective owners. No dataset images
or user photos were brought into this repository or sent to a service.

SHA-256 of the exact bundled file:

```
f0f2f52d7d79ff02d346c8f9d0c9e903407366aeea1747cdcff160c401e3e72a
```

The model signature was read from that file and real CPU inference was run in an
isolated scratch venv with ONNX Runtime 1.24.1 (the upstream model's documented
conversion/runtime version) and 1.28.0 (the Flutter plugin's Android runtime
version):

- input: `input`, float32 `[1, 3, 256, 256]`;
- outputs: `corner_heatmaps` float32 `[1, 4, 64, 64]`, and `mask_logits`
  float32 `[1, 1, 64, 64]`;
- a generated 1000×700 desk/card scene produced finite tensors, peaks around the
  synthetic card and evidence `0.477`; the same blank scene produced evidence
  `0.00175`, below the app's `0.05` review-proposal threshold.

The app preprocessing mirrors the upstream recipe: black letterbox, RGB, NCHW,
float32 in `[0,1]`. It maps each 64×64 peak center through the inverse letterbox
transform into normalized coordinates in the already-oriented preview. A
minimum heatmap-peak × mask-IoU evidence score only decides whether to surface a
proposal; it is not an auto-accept score. Every model proposal is assigned an
unreachable auto-accept threshold (1.01), must pass the app's independent quad
validator, and remains a review-only `suggestedPolygon` until the user edits,
previews and accepts it. Failure or unusable geometry falls through to the
local classical single-document detector; that detector also remains
review-only. There is no model download, upload, or Python runtime in the app.

`flutter_onnxruntime` is pinned to upstream commit
`2f0fc6c102652965004b89512b7187e6621dddf7` (MIT). It uses ONNX Runtime
1.28.0 from Maven for Android and 1.28.3 from Microsoft's GitHub release for
Windows builds; the runtime libraries are bundled into the app. Runtime
inference uses only the local bundled model. The ONNX Runtime license and the
plugin license are included under `assets/legal/`.

## DocAligner 1.1.1 FastViT-SA24 evaluation

The exact GitHub tag `1.1.1` was inspected at
`3275b0f07f8e99d8c01cb0774dea2549be1416b6`. Its code is Apache-2.0. The
`fastvit_sa24` heatmap implementation expects a 256×256 RGB NCHW float tensor
scaled to `[0,1]`; it returns four heatmaps and extracts their largest-region
centroids. The ONNX file is not in the tagged tree or the 1.1.1 PyPI wheel.
The implementation downloads `fastvit_sa24_h_e_bifpn_256_fp32.onnx` from a
Google Drive file ID at runtime. The GitHub release API has no release for the
requested model tag, and the named checkpoint could not be obtained or hashed
through the repository's available network hosts. Thus the supplied
`...7f9f5a89` identifier could not be confirmed as the file's SHA-256. The
weight's license/provenance is not stated separately from the source-code
license. It is not bundled, not downloaded by the app, and not represented as
integrated.

Because the exact DocAligner checkpoint could not be verified or acquired, the
practical second-stage alternative is the existing local classical detector,
followed by user-drawn corners. The cascade is therefore DocQuadNet-256 →
validated classical proposal when AI inference is missing/invalid → manual
review and perspective preview. This does not claim a second AI model is active.

## Evidence boundary

The scratch inference used only deterministic synthetic pixels and establishes
model loading, tensor shapes and coordinate plumbing—not accuracy on real
cards. No licensed Iraqi-card holdout set was available. The Android emulator
and Windows runtime integration tests are wired into GitHub Actions; their
results must be read from the run for the final pushed SHA. No real-device
claim is made here.
