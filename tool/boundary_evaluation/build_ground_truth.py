#!/usr/bin/env python3
"""Author the quad-level ground truth for this review pass.

WHAT THIS FILE IS. It records, for each of the 57 packaged images, what a
reviewer saw on the ORIGINAL pixels, and for each visible document instance one
of three explicit outcomes:

  confirmed   the quadrilateral was checked on the rectified crop and the crop
              shows the WHOLE document with no background band and no cut edge.
  needs_review  a plausible quadrilateral exists but the reviewer could not
              certify it (blur, occlusion, glare, partial frame) — it is kept
              so a second reviewer can finish it, never silently dropped.
  undetermined  the document is visible but no quadrilateral could be
              determined at all (too small, too blurred, no separable edge).

NO COORDINATE IS INVENTED. Every coordinate in the output comes from a machine
proposal that was either shipped with the package or produced by this
repository's drafting tools, and only the ones whose warp was inspected end up
`confirmed`. Reviewing the warp is the decision procedure because a few
percent of corner error is invisible on a thin overlay but obvious in the
rectified crop: the crop either contains the whole card or it does not.

Coordinates are normalized against the ORIGINAL image dimensions, whose pixel
size is asserted here so a coordinate can never be silently reinterpreted
against a different raster. Order is TL, TR, BR, BL.

Run:  python3 tool/boundary_evaluation/build_ground_truth.py \
          --dataset local-data/boundary-dataset \
          --out local-data/boundary-dataset/ground_truth_quad.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Image facts measured on the packaged originals: pixel size and how many
# documents a reviewer counted. `documents` is the instance count a detection
# system must reproduce; it is never inferred from the candidates.
# --------------------------------------------------------------------------
IMAGE_FACTS: dict[int, dict] = {
    # Composite sheet: six separate documents on white, all four corners
    # visible. Cropped cleanly, so they are the highest-value instances here.
    1: {"size": (4961, 7016), "documents": 6},
    # One card in a holder photographed on smooth concrete.
    2: {"size": (4961, 7016), "documents": 1},
    3: {"size": (303, 660), "documents": 1},
    4: {"size": (480, 639), "documents": 2},
    5: {"size": (387, 516), "documents": 2},
    6: {"size": (480, 640), "documents": 1},
    7: {"size": (479, 640), "documents": 2},
    8: {"size": (387, 516), "documents": 2},
    9: {"size": (768, 1024), "documents": 1},
    # Government brochure: the specimen card inside the phone mock-up is a
    # printed reproduction, not a document lying in the scene.
    10: {"size": (1638, 2048), "documents": 1},
    11: {"size": (1280, 875), "documents": 1},
    12: {"size": (1280, 1280), "documents": 1},
    13: {"size": (674, 915), "documents": 1},
    14: {"size": (304, 504), "documents": 1},
    15: {"size": (480, 342), "documents": 1},
    16: {"size": (480, 312), "documents": 1},
    17: {"size": (386, 310), "documents": 1},
    18: {"size": (386, 220), "documents": 1},
    19: {"size": (480, 320), "documents": 1},
    20: {"size": (480, 340), "documents": 1},
    21: {"size": (398, 282), "documents": 1},
    22: {"size": (398, 266), "documents": 1},
    23: {"size": (386, 278), "documents": 1},
    24: {"size": (386, 258), "documents": 1},
    25: {"size": (480, 322), "documents": 1},
    26: {"size": (480, 336), "documents": 1},
    27: {"size": (768, 554), "documents": 1},
    28: {"size": (768, 512), "documents": 1},
    29: {"size": (600, 366), "documents": 1},
    30: {"size": (399, 501), "documents": 1},
    31: {"size": (399, 501), "documents": 1},
    32: {"size": (447, 447), "documents": 1},
    33: {"size": (399, 501), "documents": 1},
    34: {"size": (259, 194), "documents": 1},
    35: {"size": (480, 640), "documents": 1},
    36: {"size": (611, 502), "documents": 1},
    37: {"size": (580, 528), "documents": 1},
    38: {"size": (480, 640), "documents": 1},
    39: {"size": (399, 501), "documents": 2},
    40: {"size": (480, 640), "documents": 1},
    41: {"size": (382, 523), "documents": 1},
    42: {"size": (399, 501), "documents": 1},
    43: {"size": (409, 488), "documents": 1},
    44: {"size": (335, 597), "documents": 1},
    45: {"size": (495, 620), "documents": 1},
    46: {"size": (415, 739), "documents": 1},
    47: {"size": (233, 150), "documents": 1},
    48: {"size": (480, 640), "documents": 1},
    49: {"size": (554, 554), "documents": 1},
    50: {"size": (481, 638), "documents": 1},
    51: {"size": (554, 554), "documents": 1},
    52: {"size": (706, 434), "documents": 1},
    53: {"size": (784, 391), "documents": 1},
    54: {"size": (640, 480), "documents": 1},
    55: {"size": (399, 501), "documents": 1},
    56: {"size": (194, 259), "documents": 1},
    57: {"size": (1198, 1198), "documents": 1},
}

# --------------------------------------------------------------------------
# Reviewer decisions. `status`: confirmed | needs_review | undetermined.
# `draft`: (image_index, instance) of the machine proposal the coordinates
# are copied from, or None when no proposal was acceptable.
# `kind` uses the vocabulary the annotation schema already defines.
# --------------------------------------------------------------------------
DECISIONS: dict[int, list[dict]] = {}


def _add(
    image_index: int,
    documents: list[tuple[str, str, tuple[int, int] | None, str]],
) -> None:
    entries = []
    for position, (kind, status, draft, note) in enumerate(documents, start=1):
        entries.append(
            {
                "instance": position,
                "kind": kind,
                "status": status,
                "draft": draft,
                "note": note,
            }
        )
    DECISIONS[image_index] = entries


_add(
    1,
    [
        ("other", "confirmed", (1, 1), "bank card, whole card inside the crop"),
        ("unifiedNationalId", "confirmed", (1, 4), "unified ID front, whole card"),
        ("other", "confirmed", (1, 6), "bank card, whole card inside the crop"),
        ("unifiedNationalId", "confirmed", (1, 2), "unified ID front, whole card"),
        ("other", "confirmed", (1, 5), "bank card, whole card inside the crop"),
        ("unifiedNationalId", "confirmed", (1, 3), "unified ID front, whole card"),
    ],
)
_add(
    2,
    [
        (
            "unknown",
            "needs_review",
            (2, 1),
            "card in a clear holder on concrete; the weak component proposal "
            "covers only the holder's top-left corner, so nothing is certified",
        )
    ],
)
_add(
    3,
    [
        (
            "other",
            "needs_review",
            (3, 2),
            "held by hand, tilted; the component draft overshoots the left "
            "card edge and includes fingers, so it is not certified",
        )
    ],
)
_add(
    4,
    [
        (
            "unifiedNationalId",
            "needs_review",
            (4, 1),
            "two cards on a table; the shipped contour candidate wraps BOTH "
            "cards (aspect 6.73) and is therefore a merge, not a boundary",
        ),
        (
            "unifiedNationalId",
            "undetermined",
            None,
            "the lower card's own boundary was never proposed",
        ),
    ],
)
_add(
    5,
    [
        (
            "unifiedNationalId",
            "confirmed",
            (5, 2),
            "unified ID front on patterned cloth, entire card inside the crop",
        ),
        (
            "unknown",
            "needs_review",
            (5, 1),
            "upper card region: the proposal covers the card and part of the "
            "cloth, so the crop is not a complete-document crop",
        ),
    ],
)
_add(
    6,
    [
        (
            "unifiedNationalId",
            "confirmed",
            (6, 1),
            "child's unified ID front, whole card inside the crop",
        )
    ],
)
_add(
    7,
    [
        (
            "unifiedNationalId",
            "needs_review",
            (7, 1),
            "two cards held in one hand; the proposal spans both cards, so it "
            "is a merge. The individual cards were not separated",
        ),
        (
            "unifiedNationalId",
            "undetermined",
            None,
            "second card boundary not separable in this pass",
        ),
    ],
)
_add(
    8,
    [
        (
            "unifiedNationalId",
            "confirmed",
            (8, 5),
            "front of a card in a holder on a wooden table, whole card",
        ),
        (
            "unknown",
            "needs_review",
            (8, 1),
            "back of the same document (handwritten fields, specimen stamp); "
            "the proposal captures the handwriting but not the card outline",
        ),
    ],
)
_add(9, [("unifiedNationalId", "confirmed", (9, 1), "whole card")])
_add(
    10,
    [
        (
            "unknown",
            "undetermined",
            None,
            "brochure: no physical document in the scene, only a printed "
            "reproduction inside a phone mock-up",
        )
    ],
)
_add(
    11,
    [
        (
            "other",
            "confirmed",
            (11, 3),
            "promotional bank card on a yellow field, whole card",
        )
    ],
)
_add(
    12,
    [
        (
            "other",
            "needs_review",
            None,
            "bank card render on a gradient; the accepted draft extends past "
            "the image edge, so no quadrilateral can be certified",
        )
    ],
)
_add(
    13,
    [
        (
            "rationCard",
            "undetermined",
            None,
            "pale ration card on pale wood; no separable outline in this pass",
        )
    ],
)
_add(
    14,
    [
        (
            "rationCard",
            "confirmed",
            (14, 1),
            "blue-bordered ration card (specimen), whole card inside the crop",
        )
    ],
)
_add(
    15,
    [
        (
            "rationCard",
            "undetermined",
            None,
            "glare dominates the frame; the card outline is not separable",
        )
    ],
)
_add(16, [("unifiedNationalId", "confirmed", (16, 3), "whole card")])
_add(17, [("unifiedNationalId", "confirmed", (17, 1), "whole card")])
_add(18, [("rationCard", "confirmed", (18, 1), "whole card")])
_add(19, [("unifiedNationalId", "confirmed", (19, 1), "whole card")])
_add(
    20,
    [
        (
            "unknown",
            "needs_review",
            None,
            "card centered in the frame on a pale surface; the best draft "
            "leaves the image, so no quadrilateral is recorded",
        )
    ],
)
_add(21, [("unifiedNationalId", "confirmed", (21, 1), "whole card")])
_add(
    22,
    [
        (
            "rationCard",
            "needs_review",
            (22, 1),
            "the only candidate lands on a blurred patch of the card's "
            "print, not on the card outline",
        )
    ],
)
_add(23, [("unifiedNationalId", "confirmed", (23, 6), "whole card")])
_add(
    24,
    [
        (
            "other",
            "undetermined",
            None,
            "bank card on a dark surface with a hard specular highlight; the "
            "single candidate is a degenerate sliver",
        )
    ],
)
_add(
    25,
    [
        (
            "unknown",
            "needs_review",
            (50, 1),
            "card region inside the frame is a pale, low-contrast smear; the "
            "only draft is a texture patch, not the card outline",
        )
    ],
)
_add(
    26,
    [
        (
            "rationCard",
            "needs_review",
            (26, 1),
            "the candidate frames the stamp and print block, not the card "
            "outline; the card fills the frame",
        )
    ],
)
_add(27, [("rationCard", "confirmed", (27, 1), "whole card")])
_add(
    28,
    [
        (
            "rationCard",
            "needs_review",
            None,
            "pale card on patterned carpet; the best draft leaves the image, "
            "so no quadrilateral is recorded",
        )
    ],
)
_add(
    29,
    [
        (
            "other",
            "confirmed",
            (29, 1),
            "bank card with a metallic relief, whole card",
        )
    ],
)
_add(30, [("unifiedNationalId", "confirmed", (30, 1), "whole card")])
_add(
    31,
    [
        (
            "unknown",
            "undetermined",
            None,
            "card fills the frame and is blurred; the shipped candidate is a "
            "thin strip across the middle",
        )
    ],
)
_add(
    32,
    [
        (
            "unifiedNationalId",
            "needs_review",
            None,
            "card on a printed background; every draft runs past the image "
            "edge or clips a card side, so no quadrilateral is recorded",
        )
    ],
)
_add(
    33,
    [
        (
            "unknown",
            "needs_review",
            (33, 1),
            "small card in a large frame; the shipped candidate is a fragment",
        )
    ],
)
_add(34, [("unifiedNationalId", "confirmed", (34, 1), "whole card")])
_add(35, [("unifiedNationalId", "confirmed", (35, 1), "whole card")])
_add(
    36,
    [
        (
            "rationCard",
            "needs_review",
            (36, 1),
            "card in a holder on woven fabric; the crop reaches the crop "
            "border on the top-left, so completeness is not certified",
        )
    ],
)
_add(37, [("unifiedNationalId", "confirmed", (37, 1), "whole card")])
_add(38, [("rationCard", "confirmed", (38, 1), "whole card")])
_add(
    39,
    [
        (
            "rationCard",
            "confirmed",
            (39, 2),
            "upper card, whole card inside the crop",
        ),
        (
            "unifiedNationalId",
            "confirmed",
            (39, 1),
            "lower card, whole card inside the crop",
        ),
    ],
)
_add(40, [("rationCard", "confirmed", (40, 1), "whole card")])
_add(41, [("passport", "confirmed", (41, 1), "open passport data page")])
_add(
    42,
    [
        (
            "unknown",
            "undetermined",
            None,
            "identification card in a sleeve on carpet; no separable outline",
        )
    ],
)
_add(
    43,
    [
        (
            "rationCard",
            "undetermined",
            None,
            "carpet fills the frame; the single candidate is a rug pattern",
        )
    ],
)
_add(44, [("rationCard", "confirmed", (44, 3), "whole card, rotated")])
_add(
    45,
    [
        (
            "rationCard",
            "confirmed",
            (45, 2),
            "card flattened from the held photo; whole card",
        )
    ],
)
_add(
    46,
    [
        (
            "unknown",
            "undetermined",
            None,
            "heavily blurred close-up; no document boundary is visible",
        )
    ],
)
_add(
    47,
    [
        (
            "rationCard",
            "needs_review",
            (47, 1),
            "sealed card face with a fingerprint smudge; the warp keeps a "
            "sliver of the surrounding surface",
        )
    ],
)
_add(48, [("unifiedNationalId", "confirmed", (48, 1), "whole card")])
_add(
    49,
    [
        (
            "other",
            "confirmed",
            (49, 1),
            "bank card, whole card inside the crop (hard shadow on the left)",
        )
    ],
)
_add(50, [("rationCard", "confirmed", (50, 2), "whole card")])
_add(
    51,
    [
        (
            "other",
            "confirmed",
            (51, 1),
            "bank card seen edge-on in a phone mock-up; whole card",
        )
    ],
)
_add(
    52,
    [
        (
            "unknown",
            "needs_review",
            (52, 1),
            "card photographed on a keyboard; the proposal fills the frame",
        )
    ],
)
_add(
    53,
    [
        (
            "other",
            "undetermined",
            None,
            "bank card lying flat on a table, only its edge band is visible; "
            "no complete boundary",
        )
    ],
)
_add(
    54,
    [
        (
            "other",
            "undetermined",
            None,
            "bank card on a light table, low contrast; no separable outline",
        )
    ],
)
_add(
    55,
    [
        (
            "other",
            "undetermined",
            None,
            "two overlapping cards at a shallow angle; no complete boundary",
        )
    ],
)
_add(
    56,
    [
        (
            "unknown",
            "undetermined",
            None,
            "tiny blurred crop of a card; no usable boundary",
        )
    ],
)
_add(
    57,
    [
        (
            "other",
            "confirmed",
            (57, 1),
            "reverse of a national card with MRZ; whole document inside the "
            "crop",
        )
    ],
)


def build(dataset: Path) -> dict:
    # Packaged candidates are addressed first because the reviewer decisions
    # reference that numbering; auto-proposals fill the images the package left
    # without any candidate.
    proposals: dict[tuple[int, int], dict] = {}
    for name in ("packaged_candidates.json", "auto_candidates.json"):
        path = dataset / name
        if not path.exists():
            raise SystemExit(f"missing proposal file: {path}")
        for entry in json.loads(path.read_text(encoding="utf-8")):
            key = (int(entry["image_index"]), int(entry["instance"]))
            proposals.setdefault(key, {**entry, "proposal_file": name})

    images = sorted(
        p for p in (dataset / "images_original").iterdir() if p.is_file()
    )
    if len(images) != len(IMAGE_FACTS):
        raise SystemExit(
            f"expected {len(IMAGE_FACTS)} images, found {len(images)}"
        )

    instances = []
    tally = {"confirmed": 0, "needs_review": 0, "undetermined": 0}
    for index, path in enumerate(images, start=1):
        facts = IMAGE_FACTS[index]
        entries = DECISIONS.get(index)
        if entries is None:
            raise SystemExit(f"image {index} has no reviewer decision")
        if len(entries) != facts["documents"]:
            raise SystemExit(
                f"image {index}: {len(entries)} decisions for "
                f"{facts['documents']} counted documents"
            )
        for entry in entries:
            draft = entry["draft"]
            points = None
            source = "none"
            if draft is not None:
                proposal = proposals.get(tuple(draft))
                if proposal is None:
                    raise SystemExit(f"image {index}: missing draft {draft}")
                points = proposal["points_norm"]
                source = proposal["source"]
            instances.append(
                {
                    "instance_id": f"img{index:03d}_doc{entry['instance']:02d}",
                    "image_index": index,
                    "filename": path.name,
                    "source_pixel_size": list(facts["size"]),
                    "instance": entry["instance"],
                    "kind": entry["kind"],
                    "status": entry["status"],
                    "points_norm": points,
                    "points_order": ["TL", "TR", "BR", "BL"],
                    "coordinate_system": "normalized_xy_of_original_image_topleft",
                    "proposal_source": source,
                    "reviewer": "R1",
                    "note": entry["note"],
                }
            )
            tally[entry["status"]] += 1

    documents = sum(facts["documents"] for facts in IMAGE_FACTS.values())
    return {
        "schema": "scan-id-boundary-quad-review-v1",
        "dataset": "scanid_boundary_annotation_candidates.zip",
        "images": len(images),
        "documents_counted": documents,
        "instances": instances,
        "tally": tally,
        "limitations": [
            "single reviewer (R1); the protocol requires two independent "
            "reviewers plus adjudication before these counts become a "
            "certified ground truth",
            "coordinates are normalized against the packaged originals after "
            "EXIF orientation, and the pixel size recorded per image is the "
            "one they were measured on",
            "an instance marked undetermined keeps its place in the count so a "
            "later pass can fill it in; dropping it would silently lower the "
            "denominator of every detection metric",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = build(args.dataset)
    args.out.write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "images": result["images"],
                "documents_counted": result["documents_counted"],
                "instances": len(result["instances"]),
                "tally": result["tally"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
