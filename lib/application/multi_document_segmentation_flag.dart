/// Whether the classical multi-document region stage may run in production.
///
/// `false` on purpose, and the reason is measured, not stylistic. The classical
/// segmenter was run against the annotated evaluation set
/// (`tool/boundary_evaluation/segmenter_port.py`, recorded in
/// `docs/BOUNDARY_AUDIT_REPORT.md`):
///
/// | Metric | Value |
/// |---|---|
/// | Instance precision | 0.4667 |
/// | Instance recall | 0.5714 |
/// | Spurious regions | 32 of 60 predicted |
/// | Documents merged into one region | 8 |
///
/// Enabling it would cut documents the user did not ask to cut, and merge
/// documents that must stay separate — two touching cards become one region, a
/// limitation the unconditionally skipped test
/// `test/imaging/document_segmenter_test.dart` names explicitly. This flag
/// therefore keeps the app on one document per photo rather than trading real
/// data for a lower document count.
///
/// It is NOT dead policy: the capability is a property of the `ProjectService`,
/// this constant is only the shipped default, and tests (and any host that
/// decides otherwise) construct the service with an explicit `true`. The
/// person's «المستندات المتعددة» option is a separate, weaker switch: it can
/// only ask for the stage on top of what the build already allows, and it can
/// never turn this capability on by itself — a user choice must not be able to
/// activate a stage the build judged unqualified.
const bool multiDocumentSegmentationEnabled = false;

/// Whether this build can honour a «المستندات المتعددة» request at all.
///
/// Derived, never restated: the sheet asks this so it can tell the person the
/// truth instead of showing a switch that silently does nothing.
const bool multiDocumentDetectionAvailable = multiDocumentSegmentationEnabled;
