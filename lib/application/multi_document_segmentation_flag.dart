/// Automatic region segmentation is disabled because this build has no
/// qualified document-region detector. In particular, the legacy classical
/// segmenter must not silently stand in for a removed/unsupported model.
///
/// This remains a separate policy from Smart Recognition so a future,
/// independently qualified detector can be opted in deliberately without
/// enabling OCR or classification. Manual crop and review stay available.
const bool multiDocumentSegmentationEnabled = false;
