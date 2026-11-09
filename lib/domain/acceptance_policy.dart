/// Provisional routing scores, never calibrated probabilities. Keep production
/// at the audited baseline until a labelled real-document evaluation justifies
/// a lower threshold. Boundary and type decisions have separate policies.
const double automaticAcceptanceThreshold = .70;
const double boundaryAcceptanceThreshold = automaticAcceptanceThreshold;
const double classificationAcceptanceThreshold = .70;

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
