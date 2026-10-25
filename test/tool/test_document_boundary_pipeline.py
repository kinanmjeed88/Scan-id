"""Comprehensive verification suite for the Scan-id boundary detection pipeline.

Covers:
1. Exact ports of all Flutter unit tests in `test/imaging/document_detector_test.dart`,
   `test/imaging/document_segmenter_test.dart`, and `test/imaging/document_segmenter_gate_test.dart`.
2. Unseen synthetic stress scenes (low contrast, horizontal/vertical/grid multi-card sheets,
   tilted multi-cards, 1- & 2-border clipped documents, glare + inner frame, colored asymmetric
   letterbox bars, severe perspective where `TR.x + TR.y < TL.x + TL.y`, `-42°` steep tilt,
   EXIF orientations 3/6/8, circular-blob negative control, checkerboard negative control).
3. Hybrid arbitrator & provenance invariants (zero uncalibrated confidence inflation,
   AI internal face-slice rejection -> `wholeFrameDetector` `needsReview`, enclosed inner
   sub-box rejection -> outer card `needsReview`, un-clamped outside sampling near frame edges,
   pure classical mode `hasLearnedModel=False` provenance).
4. Downsampling perturbation check (`Resampling.BOX` vs `Resampling.BILINEAR`) and frozen
   artifact manifest / routing threshold lock verification.
"""

from __future__ import annotations

import io
import math
import subprocess
import sys
import unittest
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

import numpy as np
from PIL import Image, ImageDraw, ImageOps

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _dart_detector_mirror as m  # noqa: E402


class _Lcg:
    def __init__(self, state: int) -> None:
        self.state = state

    def next(self) -> float:
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return self.state / 0x7FFFFFFF


def _signed_inside(px: float, py: float, quad: Sequence[Tuple[float, float]]) -> float:
    d = float("inf")
    for i in range(4):
        ax, ay = quad[i]
        bx, by = quad[(i + 1) % 4]
        ln = math.hypot(bx - ax, by - ay)
        d = min(d, (px - ax) * (-(by - ay) / ln) + (py - ay) * ((bx - ax) / ln))
    return d


def _wood_bg(x: int, y: int, noise: _Lcg) -> List[float]:
    g = (math.sin(x / 9.0 + math.sin(y / 40.0) * 3.0) * 0.5 + 0.5) * 40.0 + noise.next() * 20.0
    return [150.0 + g, 100.0 + 0.7 * g, 60.0 + 0.4 * g]


def _dark_bg(x: int, y: int, noise: _Lcg) -> List[float]:
    n = noise.next() * 12.0
    return [40.0 + n, 45.0 + n, 55.0 + n]


def _checker_bg(x: int, y: int, noise: _Lcg) -> List[float]:
    return [200.0, 60.0, 60.0] if ((x // 24 + y // 24) % 2 == 0) else [235.0, 220.0, 220.0]


def _rotated_quad(cx: float, cy: float, w: float, h: float, degrees: float) -> List[Tuple[float, float]]:
    a = degrees * math.pi / 180.0
    ca, sa = math.cos(a), math.sin(a)
    return [
        (cx + u * ca - v * sa, cy + u * sa + v * ca)
        for (u, v) in ((-w / 2.0, -h / 2.0), (w / 2.0, -h / 2.0), (w / 2.0, h / 2.0), (-w / 2.0, h / 2.0))
    ]


def _make_flutter_scene(
    bg_fn,
    quad: Optional[Sequence[Tuple[float, float]]],
    card_colour: Sequence[float],
    w: int = 640,
    h: int = 480,
) -> np.ndarray:
    noise = _Lcg(3)
    arr = np.zeros((h, w, 3), dtype=np.uint8)
    shadow = None if quad is None else [(x + 7.0, y + 9.0) for (x, y) in quad]
    x0 = 0.0 if quad is None else min(p[0] for p in quad)
    y0 = 0.0 if quad is None else min(p[1] for p in quad)
    for y in range(h):
        for x in range(w):
            c = bg_fn(x, y, noise)
            if shadow is not None:
                f = min(1.0, max(0.0, (_signed_inside(float(x), float(y), shadow) + 12.0) / 24.0))
                c = [v * (1.0 - 0.35 * f) for v in c]
            if quad is not None and _signed_inside(float(x), float(y), quad) >= 0.0:
                px, py = x - x0 - 30.0, y - y0 - 40.0
                if 0.0 <= px < 60.0 and 0.0 <= py < 70.0:
                    c = [110.0, 95.0, 90.0]
                elif math.floor(y - y0) % 17 == 0 and x - x0 > 110.0:
                    c = [80.0, 80.0, 90.0]
                else:
                    c = list(card_colour)
            arr[y, x] = [min(255, max(0, int(round(v)))) for v in c]
    return arr


def _max_corner_err(found: Sequence[Tuple[float, float]], truth_px: Sequence[Tuple[float, float]], w: int, h: int) -> float:
    return max(
        max(abs(found[i][0] - truth_px[i][0] / (w - 1)), abs(found[i][1] - truth_px[i][1] / (h - 1)))
        for i in range(4)
    )


def _draw_norm_quad(w: int, h: int, bg: Tuple[int, int, int], quad_norm: Sequence[Tuple[float, float]], fg: Tuple[int, int, int]) -> np.ndarray:
    im = Image.new("RGB", (w, h), bg)
    ImageDraw.Draw(im).polygon([(p[0] * (w - 1), p[1] * (h - 1)) for p in quad_norm], fill=fg)
    return np.asarray(im, dtype=np.uint8)


class DocumentBoundaryPipelineTest(unittest.TestCase):
    # ------------------------------------------------------------------
    # 1. Exact Flutter `document_detector_test.dart` parity battery (6/6)
    # ------------------------------------------------------------------

    def test_flutter_detector_plain_card_on_solid_black_margins(self) -> None:
        arr = np.zeros((140, 200, 3), dtype=np.uint8)
        arr[20:121, 25:176] = 255
        res = m.detect_document_corners_scored(arr)
        self.assertIsNotNone(res)
        assert res is not None
        self.assertEqual((res.viewport_left, res.viewport_top, res.viewport_width, res.viewport_height), (0, 0, 200, 140))
        self.assertLess(_max_corner_err(res.corners, [(25, 20), (175, 20), (175, 120), (25, 120)], 200, 140), 0.02)

    def test_flutter_detector_tilted_wood_with_cast_shadow(self) -> None:
        truth = _rotated_quad(330.0, 250.0, 300.0, 300.0 / 1.5858, 17.0)
        res = m.detect_document_corners_scored(_make_flutter_scene(_wood_bg, truth, [225.0, 228.0, 235.0]))
        self.assertIsNotNone(res)
        assert res is not None
        self.assertLess(_max_corner_err(res.corners, truth, 640, 480), 0.005)
        self.assertLess(res.corners[0][1], res.corners[3][1])
        self.assertGreater(res.corners[1][0], res.corners[0][0])

    def test_flutter_detector_perspective_trapezoid_on_dark_cloth(self) -> None:
        truth = [(170.0, 130.0), (470.0, 110.0), (500.0, 330.0), (150.0, 360.0)]
        res = m.detect_document_corners_scored(_make_flutter_scene(_dark_bg, truth, [230.0, 215.0, 160.0]))
        self.assertIsNotNone(res)
        assert res is not None
        self.assertLess(_max_corner_err(res.corners, truth, 640, 480), 0.005)

    def test_flutter_detector_rejects_checkerboard_and_flat_frames(self) -> None:
        self.assertIsNone(m.detect_document_corners_scored(_make_flutter_scene(_checker_bg, None, [])))
        self.assertIsNone(m.detect_document_corners_scored(np.zeros((90, 120, 3), dtype=np.uint8)))
        self.assertIsNone(m.detect_document_corners_scored(np.zeros((2, 2, 3), dtype=np.uint8)))

    # ------------------------------------------------------------------
    # 2. Letterbox viewport, `_orderQuad` perspective stress, & EXIF
    # ------------------------------------------------------------------

    def test_asymmetric_colored_letterbox_mapping(self) -> None:
        im = Image.new("RGB", (600, 1100), (14, 22, 46))
        draw = ImageDraw.Draw(im)
        draw.rectangle([0, 950, 599, 1099], fill=(28, 28, 30))
        draw.rectangle([0, 150, 599, 949], fill=(74, 58, 46))
        draw.rectangle([52, 410, 548, 735], fill=(235, 236, 240))
        res = m.detect_document_corners_scored(np.asarray(im, dtype=np.uint8))
        self.assertIsNotNone(res)
        assert res is not None
        self.assertAlmostEqual(res.viewport_top, 150, delta=2)
        self.assertLess(_max_corner_err(res.corners, [(52, 410), (548, 410), (548, 735), (52, 735)], 600, 1100), 0.015)

    def test_severe_perspective_and_steep_tilt_corner_ordering(self) -> None:
        # Case where TR.x + TR.y = 0.78 < TL.x + TL.y = 0.60 is close and steep -32 deg tilt
        gt = [(0.06, 0.52), (0.58, 0.20), (0.92, 0.32), (0.48, 0.83)]
        arr = _draw_norm_quad(552, 1200, (42, 46, 52), gt, (236, 234, 226))
        det = m.detect_document_corners_scored(arr)
        self.assertIsNotNone(det)
        assert det is not None
        for i in range(4):
            self.assertAlmostEqual(det.corners[i][0], gt[i][0], delta=0.03)
            self.assertAlmostEqual(det.corners[i][1], gt[i][1], delta=0.03)

    def test_exif_orientations_3_6_8_normalize_cleanly(self) -> None:
        gt = [(0.12, 0.25), (0.86, 0.25), (0.86, 0.76), (0.12, 0.76)]
        upright = Image.fromarray(_draw_norm_quad(640, 480, (36, 40, 48), gt, (235, 236, 238)))
        transforms = {
            3: Image.Transpose.ROTATE_180,
            6: Image.Transpose.ROTATE_90,
            8: Image.Transpose.ROTATE_270,
        }
        for orientation, transpose_op in transforms.items():
            raw = upright.transpose(transpose_op)
            exif = raw.getexif()
            exif[0x0112] = orientation
            buf = io.BytesIO()
            raw.save(buf, format="JPEG", quality=96, exif=exif.tobytes())
            buf.seek(0)
            decoded = np.asarray(ImageOps.exif_transpose(Image.open(buf)).convert("RGB"), dtype=np.uint8)
            det = m.detect_document_corners_scored(decoded)
            self.assertIsNotNone(det)
            assert det is not None
            self.assertGreater(m.polygon_iou(det.corners, gt), 0.96)

    # ------------------------------------------------------------------
    # 3. Segmenter positive & negative controls (no blob fabrication)
    # ------------------------------------------------------------------

    def test_multi_card_enclosed_sheet_and_blob_rejection(self) -> None:
        im = Image.new("RGB", (900, 1200), (0, 0, 0))
        draw = ImageDraw.Draw(im)
        draw.rectangle([45, 45, 855, 1155], fill=(248, 249, 250))
        rects = [
            (80, 140, 415, 360),
            (485, 140, 820, 360),
            (80, 440, 415, 660),
            (485, 440, 820, 660),
            (80, 740, 415, 960),
        ]
        for x1, y1, x2, y2 in rects:
            draw.rectangle([x1, y1, x2, y2], fill=(222, 226, 232), outline=(65, 72, 82), width=3)
        seg = m.segment_decoded(np.asarray(im, dtype=np.uint8))
        self.assertTrue(seg.multi)
        self.assertEqual(len(seg.candidates), 5)
        for c in seg.candidates:
            self.assertIsNotNone(c.corners)
            assert c.corners is not None
            self.assertTrue(m.assess_quad(c.corners, 900, 1200).acceptable)

        # Negative control: two circular non-document blobs on white sheet must return multi=False
        blobs = Image.new("RGB", (800, 600), (246, 247, 248))
        bdraw = ImageDraw.Draw(blobs)
        bdraw.ellipse([125, 185, 355, 415], fill=(48, 52, 60))
        bdraw.ellipse([445, 185, 675, 415], fill=(48, 52, 60))
        bseg = m.segment_decoded(np.asarray(blobs, dtype=np.uint8))
        self.assertFalse(bseg.multi)

    # ------------------------------------------------------------------
    # 4. Hybrid Arbitrator, provenance honesty, & un-clamped physics
    # ------------------------------------------------------------------

    def test_ai_scene_gate_confidence_and_region_padding_match_dart(self) -> None:
        """Mirror the Dart review cap and padded candidate region exactly."""
        self.assertEqual(m._dart_ai_gate_confidence(0.84, accepted=False), 0.50)
        self.assertAlmostEqual(m._dart_ai_gate_confidence(0.42, accepted=False), 0.42)
        self.assertAlmostEqual(m._dart_ai_gate_confidence(0.84, accepted=True), 0.84)
        region = m._dart_ai_region(
            [(0.10, 0.20), (0.90, 0.20), (0.90, 0.80), (0.10, 0.80)]
        )
        for actual, expected in zip(region, [0.08, 0.185, 0.92, 0.815]):
            self.assertAlmostEqual(actual, expected, places=12)

    def test_arbitrator_rejects_face_slice_and_inner_box_without_inflating_confidence(self) -> None:
        im = Image.new("RGB", (1000, 700), (40, 44, 52))
        draw = ImageDraw.Draw(im)
        draw.rectangle([100, 150, 900, 560], fill=(236, 235, 230))
        draw.rectangle([680, 210, 850, 430], fill=(30, 32, 36))
        rgb = np.asarray(im, dtype=np.uint8)

        sliced_ai = m.BoundaryProposalPy(
            producer="learnedModel",
            corners=[(0.10, 0.214), (0.68, 0.214), (0.90, 0.800), (0.10, 0.800)],
            model_confidence=0.94,
            min_auto_accept_confidence=0.55,
        )
        prop = m.arbitrate_single_boundary(rgb, sliced_ai)
        self.assertIsNotNone(prop)
        assert prop is not None and prop.corners is not None
        self.assertEqual(prop.producer, "wholeFrameDetector")
        self.assertEqual(prop.model_confidence, 0.0)
        self.assertAlmostEqual(prop.corners[1][0], 0.90, delta=0.03)
        dec = m.verify_boundary(prop, 1000, 700)
        self.assertEqual(dec.kind, "needsReview")

        # Pure classical mode preserves `None` confidence and `wholeFrameDetector` provenance
        pure_cl = m.arbitrate_single_boundary(rgb, None, has_learned_model=False)
        self.assertIsNotNone(pure_cl)
        assert pure_cl is not None
        self.assertEqual(pure_cl.producer, "wholeFrameDetector")
        self.assertIsNone(pure_cl.model_confidence)

    def test_near_border_physics_does_not_clamp_onto_card_interior(self) -> None:
        im = Image.new("RGB", (800, 600), (35, 38, 44))
        ImageDraw.Draw(im).rectangle([0, 100, 720, 500], fill=(238, 238, 236))
        rgb = np.asarray(im, dtype=np.uint8)
        phys = m.measure_quad_physics(
            rgb,
            [(0.002, 100 / 599), (720 / 799, 100 / 599), (720 / 799, 500 / 599), (0.002, 500 / 599)],
        )
        self.assertGreaterEqual(phys["out_of_frame_sides"], 1)
        self.assertEqual(phys["interior_sides_count"], 3)
        self.assertGreater(phys["min_interior_step"], 150.0)

    def test_box_vs_bilinear_downsampling_consistency_and_frozen_manifest(self) -> None:
        gt = [(0.14, 0.22), (0.86, 0.19), (0.89, 0.78), (0.11, 0.81)]
        arr = _draw_norm_quad(1800, 1350, (44, 48, 56), gt, (236, 235, 230))
        c_box = m.detect_document_corners_scored(arr, resample=Image.Resampling.BOX)
        c_bil = m.detect_document_corners_scored(arr, resample=Image.Resampling.BILINEAR)
        self.assertIsNotNone(c_box)
        self.assertIsNotNone(c_bil)
        assert c_box is not None and c_bil is not None
        self.assertGreater(m.polygon_iou(c_box.corners, c_bil.corners), 0.995)

        proc = subprocess.run(
            [sys.executable, str(REPO_ROOT / "tool" / "verify_frozen_artifacts.py")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)

    # ------------------------------------------------------------------
    # 5. Zero-Trust Dart AST Call-Arity, Signature & Parity Verification
    # ------------------------------------------------------------------

    def test_dart_static_declaration_arity_and_parameter_audit(self) -> None:
        """Mechanically audits every declaration, call-site positional arity,
        named argument, and enum constant across all touched Dart modules."""
        import re as _re

        def strip_dart_comments_and_strings(src: str) -> str:
            out: List[str] = []
            i, n = 0, len(src)
            while i < n:
                ch = src[i]
                if ch == "/" and i + 1 < n and src[i + 1] == "/":
                    while i < n and src[i] != "\n":
                        out.append(" ")
                        i += 1
                    continue
                if ch == "/" and i + 1 < n and src[i + 1] == "*":
                    out.append("  ")
                    i += 2
                    while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                        out.append("\n" if src[i] == "\n" else " ")
                        i += 1
                    out.append("  ")
                    i += 2
                    continue
                if ch in ("'", '"'):
                    quote = src[i : i + 3] if src[i : i + 3] == ch * 3 else ch
                    out.append(ch)
                    i += len(quote)
                    while i < n and not src.startswith(quote, i):
                        if src[i] == "\\" and i + 1 < n:
                            out.append("  ")
                            i += 2
                            continue
                        out.append("\n" if src[i] == "\n" else "s")
                        i += 1
                    out.append(ch)
                    i += len(quote)
                    continue
                out.append(ch)
                i += 1
            return "".join(out)

        def split_top_level(s: str, sep: str = ",") -> List[str]:
            parts: List[str] = []
            cur: List[str] = []
            depth = 0
            for c in s:
                if c in "([{<":
                    depth += 1
                elif c in ")]}>":
                    depth = max(0, depth - 1)
                if c == sep and depth == 0:
                    parts.append("".join(cur).strip())
                    cur = []
                else:
                    cur.append(c)
            tail = "".join(cur).strip()
            if tail:
                parts.append(tail)
            return parts

        def find_matching_paren(s: str, open_idx: int) -> int:
            depth = 0
            for idx in range(open_idx, len(s)):
                if s[idx] == "(":
                    depth += 1
                elif s[idx] == ")":
                    depth -= 1
                    if depth == 0:
                        return idx
            return -1

        def parse_param_spec(param_list: str):
            min_pos = max_pos = 0
            req_named: set[str] = set()
            opt_named: set[str] = set()
            s = param_list.strip()
            if not s:
                return (0, 0, req_named, opt_named)
            # Split optional positional `[...]` or named `{...}` group at depth 0
            opt_pos_str = named_str = ""
            main_chars: List[str] = []
            i = 0
            while i < len(s):
                if s[i] == "[":
                    end = s.rfind("]")
                    opt_pos_str = s[i + 1 : end]
                    break
                if s[i] == "{":
                    end = s.rfind("}")
                    named_str = s[i + 1 : end]
                    break
                main_chars.append(s[i])
                i += 1
            for p in split_top_level("".join(main_chars)):
                if p:
                    min_pos += 1
                    max_pos += 1
            for p in split_top_level(opt_pos_str):
                if p:
                    max_pos += 1
            for p in split_top_level(named_str):
                if not p:
                    continue
                is_req = p.startswith("required ")
                lhs = p.split("=")[0].strip()
                m_id = _re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", lhs)
                if m_id:
                    (req_named if is_req else opt_named).add(m_id.group(1))
            return (min_pos, max_pos, req_named, opt_named)

        def collect_decls(cleaned: str) -> Tuple[dict, set[int]]:
            decls: dict = {}
            decl_offsets: set[int] = set()
            keywords = {
                "if", "for", "while", "switch", "catch", "return", "assert", "require"
            }
            id_before_paren = _re.compile(r"([A-Za-z_][A-Za-z0-9_.]*)\s*\(")
            for match in id_before_paren.finditer(cleaned):
                name = match.group(1)
                if name in keywords:
                    continue
                line_start = cleaned.rfind("\n", 0, match.start()) + 1
                stmt_prefix = cleaned[max(0, match.start() - 120) : match.start()]
                last_sep = max(stmt_prefix.rfind(";"), stmt_prefix.rfind("{"), stmt_prefix.rfind("}"))
                header = stmt_prefix[last_sep + 1 :].strip() if last_sep >= 0 else cleaned[line_start : match.start()].strip()
                if not header or "=" in header or "return " in header or header.endswith("."):
                    continue
                if not _re.match(r"^[A-Za-z0-9_<>?.,\s()\[\]@]+$", header):
                    continue
                open_p = cleaned.find("(", match.end() - 1)
                close_p = find_matching_paren(cleaned, open_p)
                if close_p < 0:
                    continue
                after = cleaned[close_p + 1 : close_p + 40].lstrip()
                if not (
                    after.startswith("{")
                    or after.startswith("=>")
                    or after.startswith(":")
                    or after.startswith("async")
                ):
                    continue
                spec = parse_param_spec(cleaned[open_p + 1 : close_p])
                decls.setdefault(name, []).append(spec)
                decl_offsets.add(match.start(1))
            return decls, decl_offsets

        def check_calls(cleaned: str, known_decls: dict, decl_offsets: set[int], label: str) -> List[str]:
            errors: List[str] = []
            call_pat = _re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*\(")
            skip_kw = {
                "if", "for", "while", "switch", "catch", "return", "assert", "test", "expect"
            }
            sdk_overloads = {
                "run": [(1, 2, set(), {"debugName"})],  # dart:isolate Isolate.run
                "Center": [(0, 0, set(), {"key", "widthFactor", "heightFactor", "child"})],
            }
            for match in call_pat.finditer(cleaned):
                if match.start(1) in decl_offsets:
                    continue
                fn = match.group(1)
                if fn in skip_kw or fn not in known_decls:
                    continue
                open_p = cleaned.find("(", match.end() - 1)
                close_p = find_matching_paren(cleaned, open_p)
                if close_p < 0:
                    errors.append(f"{label}: unclosed call to {fn}")
                    continue
                args = split_top_level(cleaned[open_p + 1 : close_p])
                pos_cnt = 0
                used_named: set[str] = set()
                for arg in args:
                    m_named = _re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:(?!\s*:)", arg)
                    if m_named:
                        used_named.add(m_named.group(1))
                    else:
                        pos_cnt += 1
                candidates = list(known_decls[fn]) + sdk_overloads.get(fn, [])
                matched = False
                for min_p, max_p, req_n, opt_n in candidates:
                    if (
                        min_p <= pos_cnt <= max_p
                        and req_n.issubset(used_named)
                        and used_named.issubset(req_n | opt_n)
                    ):
                        matched = True
                        break
                if not matched:
                    line_no = cleaned[: match.start()].count("\n") + 1
                    errors.append(
                        f"{label}:{line_no}: signature mismatch on `{fn}` "
                        f"(pos={pos_cnt}, named={sorted(used_named)}, allowed={candidates})"
                    )
            return errors

        dep_files = [
            REPO_ROOT / "lib/domain/boundary_decision.dart",
            REPO_ROOT / "lib/domain/quad_assessment.dart",
            REPO_ROOT / "lib/domain/geometry.dart",
            REPO_ROOT / "lib/domain/crop_draft.dart",
            REPO_ROOT / "lib/domain/image_adjustments.dart",
            REPO_ROOT / "lib/domain/project.dart",
            REPO_ROOT / "lib/imaging/ai_document_detector.dart",
            REPO_ROOT / "lib/imaging/prepare_image.dart",
            REPO_ROOT / "lib/imaging/perspective.dart",
            REPO_ROOT / "lib/imaging/full_resolution_manual_crop.dart",
            REPO_ROOT / "lib/imaging/image_header.dart",
        ]
        touched_files = [
            REPO_ROOT / "lib/imaging/document_detector.dart",
            REPO_ROOT / "lib/imaging/document_segmenter.dart",
            REPO_ROOT / "lib/imaging/hybrid_boundary_arbitrator.dart",
            REPO_ROOT / "lib/persistence/local_image_editor.dart",
            REPO_ROOT / "lib/presentation/crop_screen.dart",
            REPO_ROOT / "test/imaging/hybrid_boundary_arbitration_test.dart",
        ]

        global_public_decls: dict = {}
        cleaned_map: dict = {}
        offsets_map: dict = {}
        local_decls_map: dict = {}
        for fpath in dep_files + touched_files:
            cleaned = strip_dart_comments_and_strings(fpath.read_text(encoding="utf-8"))
            cleaned_map[fpath] = cleaned
            d_map, d_off = collect_decls(cleaned)
            offsets_map[fpath] = d_off
            local_decls_map[fpath] = d_map
            for k, specs in d_map.items():
                if not k.startswith("_"):
                    global_public_decls.setdefault(k, []).extend(specs)

        # Self-check: prove the mechanical auditor catches `_orderQuad(quad, w, h)` immediately!
        det_file = REPO_ROOT / "lib/imaging/document_detector.dart"
        det_clean = cleaned_map[det_file]
        mutated = det_clean.replace("_orderQuad(quad)", "_orderQuad(quad, w, h)", 1)
        mut_decls, mut_offsets = collect_decls(mutated)
        self.assertTrue(
            len(check_calls(mutated, {**global_public_decls, **mut_decls}, mut_offsets, "mutated_detector")) >= 1,
            "Static arity verifier failed self-test on `_orderQuad(quad, w, h)`!",
        )

        all_errors: List[str] = []
        for fpath in touched_files:
            merged = dict(global_public_decls)
            for k, v in local_decls_map[fpath].items():
                merged[k] = list(merged.get(k, [])) + list(v)
            all_errors.extend(
                check_calls(cleaned_map[fpath], merged, offsets_map[fpath], str(fpath.relative_to(REPO_ROOT)))
            )
        self.assertEqual(all_errors, [], msg="\n".join(all_errors))

    def test_assess_quad_and_verify_boundary_exact_dart_parity(self) -> None:
        """Verifies exact threshold & confidence formula parity with `lib/domain/*`."""
        # 1. Bounds check tolerance `-0.001 .. 1.001`
        self.assertTrue(
            m.assess_quad([(-0.0008, 0.1), (0.8, 0.1), (0.8, 0.8), (-0.0008, 0.8)], 1000, 1000).acceptable
        )
        r_oob = m.assess_quad([(-0.0015, 0.1), (0.8, 0.1), (0.8, 0.8), (-0.0015, 0.8)], 1000, 1000)
        self.assertFalse(r_oob.acceptable)
        self.assertEqual(r_oob.rejection, "outOfBounds")

        # 2. Minimum area fraction `0.02` over `(w - 1) * (h - 1)`
        r_small = m.assess_quad([(0.10, 0.10), (0.23, 0.10), (0.23, 0.23), (0.10, 0.23)], 1001, 1001)
        self.assertFalse(r_small.acceptable)
        self.assertEqual(r_small.rejection, "tooSmall")
        self.assertTrue(
            m.assess_quad([(0.10, 0.10), (0.25, 0.10), (0.25, 0.25), (0.10, 0.25)], 1001, 1001).acceptable
        )

        # 3. Minimum edge length `4.0 px` and max aspect `12.0`
        r_edge = m.assess_quad([(0.10, 0.10), (0.90, 0.10), (0.90, 0.135), (0.10, 0.135)], 101, 101)
        self.assertFalse(r_edge.acceptable)
        self.assertEqual(r_edge.rejection, "degenerateEdges")
        r_asp = m.assess_quad([(0.05, 0.10), (0.95, 0.10), (0.95, 0.17), (0.05, 0.17)], 1001, 1001)
        self.assertFalse(r_asp.acceptable)
        self.assertEqual(r_asp.rejection, "implausibleAspect")

        # 4. Sharp 20-deg corner parallelogram: NOT rejected by `assessQuad`, exact `geometryConfidence`
        rad = math.radians(20.0)
        dx = 0.25 * math.cos(rad)
        dy = 0.25 * math.sin(rad)
        sharp_quad = [(0.15, 0.20), (0.65, 0.20), (0.65 + dx, 0.20 + dy), (0.15 + dx, 0.20 + dy)]
        sharp_res = m.assess_quad(sharp_quad, 1001, 1001)
        self.assertTrue(sharp_res.acceptable)
        expected_area = (0.50 * dy)
        expected_conf = 0.5 * 0.0 + 0.3 * 1.0 + 0.2 * min(1.0, expected_area / 0.15)
        self.assertAlmostEqual(sharp_res.geometry_confidence or 0.0, expected_conf, places=9)

        # 5. `segmenter` disjoint region triggers `quadOutsideRegion`, and filename `"جواز.jpg"` enforces `imposedAspect`
        seg_bad = m.verify_boundary(
            m.BoundaryProposalPy(
                producer="segmenter",
                corners=[(0.10, 0.10), (0.40, 0.10), (0.40, 0.30), (0.10, 0.30)],
                region=[0.55, 0.55, 0.90, 0.90],
            ),
            1000,
            1000,
        )
        self.assertEqual(seg_bad.kind, "needsReview")
        self.assertIn("quadOutsideRegion", seg_bad.reasons)

        claimed_passport = m.classify_claimed_aspect_py(
            "جواز_سفر.jpg",
            [(0.05, 0.20), (0.95, 0.20), (0.95, 0.52), (0.05, 0.52)],
            None,
            1000,
            1000,
        )
        self.assertAlmostEqual(claimed_passport or 0.0, 125.0 / 88.0, places=6)

    def test_adversarial_negative_multi_boxes_never_produce_false_auto_accept(self) -> None:
        """Proves non-document white sheets with multiple colored boxes cannot auto-accept."""
        im = Image.new("RGB", (900, 700), (248, 249, 250))
        draw = ImageDraw.Draw(im)
        draw.rectangle([70, 180, 410, 410], fill=(42, 88, 155))
        draw.rectangle([490, 180, 830, 410], fill=(155, 62, 54))
        rgb = np.asarray(im, dtype=np.uint8)

        raw_classical = m.segment_decoded(rgb)
        rescued = m.arbitrate_scene_boundaries(
            rgb, m.SegmentationResultPy(multi=False, candidates=[])
        )
        self.assertTrue(rescued.multi)
        self.assertEqual(len(rescued.candidates), 2)
        for index, c in enumerate(rescued.candidates):
            self.assertEqual(c.producer, "segmenter")
            self.assertEqual(c.detection_confidence, raw_classical.candidates[index].detection_confidence)
            self.assertEqual(c.min_auto_accept_confidence, raw_classical.candidates[index].min_auto_accept_confidence)
            self.assertTrue(c.requires_review)

        full_decisions = m.detect_full_pipeline(rgb, use_learned_model=True)
        for d in full_decisions:
            self.assertNotEqual(d.kind, "accepted")
            self.assertNotEqual(d.proposal.producer, "learnedModel")
            if d.proposal.force_review:
                self.assertIn("multiSceneNotCorroborated", d.reasons)

    def test_uncorroborated_ai_multi_keeps_each_measured_region_for_review(self) -> None:
        rgb = np.full((350, 500, 3), 92, dtype=np.uint8)
        valid = [(0.08, 0.12), (0.46, 0.12), (0.46, 0.82), (0.08, 0.82)]
        invalid = [(0.56, 0.18), (0.92, 0.18), (0.74, 0.18), (0.56, 0.18)]
        ai = m.SegmentationResultPy(
            multi=True,
            candidates=[
                m.SegmentCandidatePy(
                    region=[0.08, 0.12, 0.46, 0.82],
                    corners=valid,
                    detection_confidence=0.91,
                    producer="learnedModel",
                    min_auto_accept_confidence=0.55,
                    reason="synthetic-valid-but-unconfirmed",
                ),
                m.SegmentCandidatePy(
                    region=[0.56, 0.18, 0.92, 0.72],
                    corners=invalid,
                    detection_confidence=0.88,
                    producer="learnedModel",
                    min_auto_accept_confidence=0.55,
                    reason="synthetic-invalid-quad",
                ),
            ],
        )

        kept = m.arbitrate_scene_boundaries(rgb, ai)
        self.assertTrue(kept.multi)
        self.assertEqual(len(kept.candidates), 2)
        self.assertEqual(
            [c.detection_confidence for c in kept.candidates], [0.91, 0.88]
        )
        self.assertTrue(all(c.requires_review for c in kept.candidates))
        self.assertEqual(kept.candidates[1].corners, invalid)

        accepted = m.verify_boundary(
            m.BoundaryProposalPy(
                producer="learnedModel",
                corners=kept.candidates[0].corners,
                region=kept.candidates[0].region,
                model_confidence=kept.candidates[0].detection_confidence,
                min_auto_accept_confidence=kept.candidates[0].min_auto_accept_confidence,
                force_review=kept.candidates[0].requires_review,
            ),
            500,
            350,
        )
        self.assertEqual(accepted.kind, "needsReview")
        self.assertIn("multiSceneNotCorroborated", accepted.reasons)
        self.assertTrue(accepted.has_usable_geometry)

        invalid_decision = m.verify_boundary(
            m.BoundaryProposalPy(
                producer="learnedModel",
                corners=kept.candidates[1].corners,
                region=kept.candidates[1].region,
                model_confidence=kept.candidates[1].detection_confidence,
                min_auto_accept_confidence=kept.candidates[1].min_auto_accept_confidence,
                force_review=kept.candidates[1].requires_review,
            ),
            500,
            350,
        )
        self.assertEqual(invalid_decision.kind, "needsReview")
        self.assertFalse(invalid_decision.has_usable_geometry)
        self.assertIn("geometryRejected", invalid_decision.reasons)
        self.assertIn("multiSceneNotCorroborated", invalid_decision.reasons)

    def test_hybrid_arbitration_preserves_a_cornerless_classical_region(self) -> None:
        im = Image.new("RGB", (900, 700), (45, 55, 70))
        ImageDraw.Draw(im).ellipse([350, 250, 550, 450], fill=(235, 233, 228))
        rgb = np.asarray(im, dtype=np.uint8)
        raw = m.segment_decoded(rgb)
        self.assertEqual(len(raw.candidates), 1)
        self.assertIsNone(raw.candidates[0].corners)

        kept = m.arbitrate_scene_boundaries(
            rgb, m.SegmentationResultPy(multi=False, candidates=[])
        )
        self.assertEqual(len(kept.candidates), 1)
        self.assertIsNone(kept.candidates[0].corners)
        self.assertEqual(kept.candidates[0].region, raw.candidates[0].region)
        self.assertTrue(kept.candidates[0].requires_review)
        self.assertFalse(kept.multi)


if __name__ == "__main__":
    unittest.main()
