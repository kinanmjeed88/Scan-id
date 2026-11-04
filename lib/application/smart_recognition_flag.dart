/// Smart Recognition feature flag.
///
/// This is an APP-LEVEL switch, never part of the project schema (a project
/// only records whether recognition was applied, by the presence of
/// `documents`).
///
/// There are two distinct values on purpose:
///
/// * [smartRecognitionEnabled] is the default a host gets when it says nothing.
///   It stays `false`, so a test, a script or an embedding that constructs
///   `ProjectService` without an opinion keeps the legacy, recognition-free
///   intake it was written against.
/// * [appSmartRecognitionEnabled] is the policy the shipped application
///   applies at its single composition root (`lib/main.dart`). The PP-OCRv5
///   engine, the multi-evidence classifier and the A4 eligibility path are
///   implemented and verified, so the app runs them; an import still needs
///   human confirmation before anything reaches the sheet.
///
/// Multi-document segmentation is a separate flag and stays disabled. The
/// v4→v5 migration is independent of both flags (legacy inline recognition is
/// always migrated on save), and manual workflows remain available either way.
library;

/// Default for hosts that do not opt in: the legacy intake path.
const bool smartRecognitionEnabled = false;

/// The policy the released application applies at its composition root.
const bool appSmartRecognitionEnabled = true;

/// Convenience accessor so call sites have a single, testable seam.
bool smartRecognitionAllows(bool requested) =>
    requested && appSmartRecognitionEnabled;
