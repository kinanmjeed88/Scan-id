/// Smart Recognition feature flag.
///
/// This is an APP-LEVEL switch, never part of the project schema (a project
/// only records whether recognition was applied, by the presence of
/// `documents`).
///
/// It is OFF by default in this build. While OFF, imports use the existing
/// legacy intake: the Phase 1B multi-document segmenter does not run, and no
/// new evidence, pairing, or review records are created. The v4→v5
/// migration is independent of this flag (legacy inline recognition is always
/// migrated on save), and manual workflows remain available. Enabling the
/// pipeline requires an explicit build-level change and owner approval.
library;

/// Whether the Smart Recognition pipeline may run.
const bool smartRecognitionEnabled = true;

/// Convenience accessor so call sites have a single, testable seam.
bool smartRecognitionAllows(bool flag) => flag && smartRecognitionEnabled;
