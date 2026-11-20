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
/// decides otherwise) construct the service with an explicit `true`.
/// Manual multi-selection never enables or invokes segmentation.
const bool multiDocumentSegmentationEnabled = false;

/// Availability of automatic (not manual) region detection.
const bool multiDocumentDetectionAvailable = multiDocumentSegmentationEnabled;
