/// Smart Recognition feature flag.
///
/// This is an APP-LEVEL switch, never part of the project schema (a project
/// only records whether recognition was applied, by the presence of
/// `documents`).
///
/// It is ON in this build: the import intake (`arrangeImportedImages`)
/// consults it and runs the Smart Recognition pipeline — segmentation,
/// geometry scoring, hybrid classification, evidence fusion, records and
/// review routing. While OFF, the import path is byte-for-byte the legacy
/// intake: no segmentation, OCR, classifier records, pairing or review state
/// is created for a freshly-imported project. The v4→v5 migration is
/// independent of this flag (legacy inline recognition is always migrated on
/// save, exactly as before), and every manual workflow works identically in
/// both positions.
library;

/// Whether the Smart Recognition pipeline may run.
const bool smartRecognitionEnabled = true;

/// Convenience accessor so call sites have a single, testable seam.
bool smartRecognitionAllows(bool flag) => flag && smartRecognitionEnabled;
