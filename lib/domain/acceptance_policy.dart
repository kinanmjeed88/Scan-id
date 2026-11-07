/// User-requested automatic acceptance threshold. These model/evidence scores
/// are routing heuristics, not calibrated probabilities or accuracy claims.
const double automaticAcceptanceThreshold = .70;

/// Missing, non-finite, and out-of-range scores never grant permission. A tiny
/// tolerance prevents weighted floating-point arithmetic from demoting an
/// exactly 70% input to 69.99999999999999%.
bool meetsAutomaticAcceptanceThreshold(double? score) =>
    score != null &&
    score.isFinite &&
    score >= automaticAcceptanceThreshold - 1e-12 &&
    score <= 1;
