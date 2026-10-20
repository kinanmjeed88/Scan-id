/// Smart Recognition feature flag.
///
/// This is an APP-LEVEL switch, never part of the project schema (a project
/// only records whether recognition was applied, by the presence of
/// `documents`).
///
/// It is OFF by default in this build. While OFF, a single-document import
/// stays on the legacy intake and does not create recognition records.
/// Multi-document segmentation is a separate flag and still runs; when it
/// finds more than one region it hands that source to SmartIntake. The v4→v5
/// migration is independent of this flag (legacy inline recognition is always
/// migrated on save), and manual workflows remain available. Enabling the
/// pipeline requires an explicit build-level change and owner approval.
library;

/// Whether the Smart Recognition pipeline may run.
const bool smartRecognitionEnabled = false;

/// Convenience accessor so call sites have a single, testable seam.
bool smartRecognitionAllows(bool flag) => flag && smartRecognitionEnabled;
