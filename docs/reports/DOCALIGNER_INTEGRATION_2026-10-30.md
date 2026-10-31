# DocAligner 1.1.1 integration record

## Pinned upstream artifact

- Repository/tag: `DocsaidLab/DocAligner`, release `1.1.1`, source tag commit `3275b0f07f8e99d8c01cb0774dea2549be1416b6`.
- Official GitHub Release asset ID: `626727748`.
- Filename: `fastvit_sa24_h_e_bifpn_256_fp32.onnx`.
- Packaged asset name: `assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx`.
- Published and required byte length: `83,084,930`.
- Published and required SHA-256: `7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc`.
- Acquisition: `tool/fetch_docaligner_model.py` reads the official release API, verifies tag, asset ID, name, size and published digest, downloads only the API-advertised browser URL, then independently verifies the downloaded bytes before making the asset available to Flutter. It refuses to replace an existing file with a nonmatching hash. The app never downloads weights.

## Model interface and image geometry

Upstream `docaligner/heatmap_reg/infer.py` at tag 1.1.1 specifies a direct resize to `(256, 256)`, HWC-to-NCHW `float32`, division by 255, and no mean/std normalization or center crop by default. Its README converts the RGB example image to BGR before calling the model. The Flutter adapter therefore sends `B,G,R` planes in `[1,3,256,256]` order, each normalized to `[0,1]`.

The ONNX session's actual input/output names are discovered from the loaded model, not guessed. Runtime checks require one input and one float32 output shaped `[1,4,H,W]`, four ordered corner heatmaps, finite probability values, and valid map dimensions. Postprocessing uses the upstream 0.3 heatmap threshold and largest-component centroid per channel; normalized heatmap centroids map independently to the oriented source width and height. Every result passes `verifyBoundary`. The ONNX adapter has no Python dependency and has no network path.

## Runtime policy

`BoundaryProposalCascade` calls DocQuadNet-256 first and DocAligner second even when DocQuadNet returns geometrically usable corners: neither confidence score is calibrated on a labelled Iraqi-card holdout, so every AI result remains uncertain. Both model outputs pass the shared geometry gate. If both are valid and corresponding corners differ by more than 4% of the image diagonal, the primary corners are retained only as an editable suggestion with `modelDisagreement`; no point averaging or automatic crop occurs. When only DocAligner has usable geometry, its proposal is retained for review. If DocAligner fails or has no usable result, the cascade returns no AI proposal and the existing local classical detector runs; if that also fails, manual corners remain available. The accepted crop path continues to use the original image and user approval.

## Evidence and limits

The integration test checks the actual bundled asset byte count and SHA-256, creates an ONNX Runtime session, executes `session.run`, checks the returned real tensor shape, and calls DocAligner through the production cascade. Android instrumentation and Windows integration-test runs are the required platform evidence; CI logs will determine whether the GitHub runner can fetch the release asset and whether both native runtimes support all model operators. Synthetic input is only a runtime/contract test, not an accuracy benchmark.

## Licensing and distribution

- **DocAligner source code:** the tag contains an Apache-2.0 `LICENSE`; this applies to the licensed source work.
- **FastViT-SA24 weight:** the release publishes the binary and a digest, but the inspected release notes and checkpoint README do not state a separate weight licence or explicit redistribution grant. The source-code licence is not attributed to this weight.
- **Training data:** the inspected tag/release does not identify a training dataset or establish its rights.
- **Scan-id redistribution:** not cleared by the available evidence. The workflows include the verified model only to run CI/build-time offline-runtime tests and produce short-lived CI test artifacts. Do not treat those artifacts as an approved public product release until weight redistribution terms and any training-data conditions are confirmed. The Android/Windows app itself performs no weight download at runtime.
