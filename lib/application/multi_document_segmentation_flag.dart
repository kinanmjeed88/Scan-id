/// Multi-document splitting is an independent import policy, not Smart
/// Recognition. It only routes a source through the existing review pipeline
/// when the local segmenter finds more than one usable region; single-document
/// imports keep the legacy path.
///
/// Kept separate from `smartRecognitionEnabled` deliberately: enabling this
/// must never enable OCR, classification, or full Smart Recognition for every
/// imported image.
const bool multiDocumentSegmentationEnabled = true;
