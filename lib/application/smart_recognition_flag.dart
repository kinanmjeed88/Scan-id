/// Smart Recognition feature flag (Phase 1B scaffolding).
///
/// This is an APP-LEVEL switch, never part of the project schema (a project only
/// records whether recognition was applied, by the presence of `documents`).
///
/// It starts OFF. While OFF, the import path is byte-for-byte unchanged: no
/// recognition, detection, OCR, classifier, pairing, or review runs, and no
/// `DocumentRecord` is created for a freshly-imported project. The v4→v5
/// migration is independent of this flag (legacy inline recognition is always
/// migrated on save, exactly as before).
///
/// Phase 1B intentionally does NOT wire this gate into any existing code path —
/// there is no recognition runtime to guard yet. When that pipeline lands
/// (later phase), the import boundary consults [smartRecognitionEnabled] and
/// takes the legacy path when it is false. Keeping it unwired here guarantees
/// that turning the feature on later cannot silently change today's import.
library;

/// Whether the Smart Recognition pipeline may run. OFF by default.
const bool smartRecognitionEnabled = false;

/// Convenience accessor so call sites have a single, testable seam.
bool smartRecognitionAllows(bool flag) => flag && smartRecognitionEnabled;
