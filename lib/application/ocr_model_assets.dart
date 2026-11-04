/// Pinned identities of the bundled OCR model files (ADR-010).
///
/// The files are produced at build/CI time by `tool/fetch_ocr_models.py` from the
/// pinned upstream revisions recorded in [ocrModelProvenance] and verified
/// against their published SHA-256 before they are used. They are git-ignored
/// (12.8 MiB of weights belongs in a release, not in the history), exactly like
/// the existing DocAligner weight.
library;

/// Detection graph: PP-OCRv5 mobile DB text-line detector, ONNX, Apache-2.0.
const String ocrDetectionAssetPath = 'assets/models/ppocrv5_mobile_det.onnx';

/// Recognition graph: PP-OCRv5 mobile Arabic CTC recogniser, ONNX, Apache-2.0.
const String ocrRecognizerAssetPath =
    'assets/models/ppocrv5_arabic_mobile_rec.onnx';

/// Character dictionary exported with the Arabic recognition model.
const String ocrDictionaryAssetPath = 'assets/ocr/ppocrv5_arabic_dict.txt';

/// Engine version recorded in provenance for every OCR confidence produced by
/// this build. Bump it whenever the tensors, the decoder or the models change,
/// so a stored result can never be attributed to a different pipeline.
const String ocrEngineVersion = 'ppocrv5-ar-mobile.ort-1';

/// Where the model files come from, for the audit trail and the licence screen.
const Map<String, String> ocrModelProvenance = {
  ocrDetectionAssetPath:
      'PaddlePaddle/PP-OCRv5_mobile_det_onnx@'
      'e6f4fa85f00e168c862bc462aebca69eef9b3d3d (Apache-2.0)',
  ocrRecognizerAssetPath:
      'PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx@'
      '14aaedcd75825982689ecf5cd64ab33ee083215a (Apache-2.0)',
  ocrDictionaryAssetPath:
      'PaddlePaddle/PaddleOCR@8ee4a20cc64fe2d73adf96110f9c9b1c3b7b85a5 '
      'ppocr/utils/dict/ppocrv5_arabic_dict.txt (Apache-2.0)',
};
