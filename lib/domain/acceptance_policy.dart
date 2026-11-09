/// Production decision thresholds requested for independent text and boundary
/// acceptance. Scores are routing evidence, not calibrated probabilities.
/// Neither threshold bypasses semantic uniqueness or geometric safety.
const double automaticAcceptanceThreshold = .55;
const double boundaryAcceptanceThreshold = automaticAcceptanceThreshold;
const double classificationAcceptanceThreshold = .60;

/// Explicit threshold injection is for controlled policy comparisons. Invalid
/// thresholds/scores fail closed. It does not bypass geometric safety gates.
bool meetsAcceptanceThreshold(double? score, double threshold) =>
    threshold.isFinite &&
    threshold > 0 &&
    threshold <= 1 &&
    score != null &&
    score.isFinite &&
    score >= threshold - 1e-12 &&
    score <= 1;

bool meetsAutomaticAcceptanceThreshold(double? score) =>
    meetsAcceptanceThreshold(score, boundaryAcceptanceThreshold);
