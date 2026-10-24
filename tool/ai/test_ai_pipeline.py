"""Automated verification suite for ScanIdDocNet-v1 ONNX artifacts, split
disjointness, raw protobuf wire parser parity (`lib/imaging/onnx_lite_runtime.dart`),
false-crop prevention, tilted card 4-corner localization, and multi-card separation."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import unittest

import cv2
import numpy as np
from PIL import Image

cv2.setNumThreads(0)

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tool.ai.dataset_gen import (
    CATALOG_SPECS,
    canonicalize_quad_clockwise_tl,
    load_disjoint_background_pools,
    load_disjoint_specimen_pools,
    polygon_iou,
    render_procedural_background,
    render_specimen_card_texture,
    sample_quad_homography,
    shrink_polygon_toward_centroid,
    warp_card_onto_scene,
)
from tool.ai.inference_pipeline import (
    FrozenThresholds,
    TwoStageOnnxDetector,
    bilinear_resize_rgb_to_chw,
)

# Cross-check the last production boundary arbitration stage. The mirror is
# still diagnostic only; Flutter/Dart exercises this same failing fixture in
# test/imaging/ai_document_detector_test.dart.
_TEST_TOOL_DIR = REPO_ROOT / "test" / "tool"
if str(_TEST_TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(_TEST_TOOL_DIR))
import _dart_detector_mirror as boundary_mirror


def _boundary_proposals_from_detection(
    result,
) -> list[boundary_mirror.BoundaryProposalPy]:
    proposals = []
    for candidate in result.candidates:
        # Match AiQuadProposal.toBoundaryProposal(): rejected model claims keep
        # their measured corners for review, but their gate confidence is capped
        # below the auto-accept threshold. Never substitute geom_confidence for
        # calibrated confidence or infer acceptance from the fixture name.
        confidence = float(candidate.confidence)
        if candidate.verdict != "accepted":
            confidence = min(confidence, 0.50)
        proposals.append(
            boundary_mirror.BoundaryProposalPy(
                producer="learnedModel",
                corners=[
                    (float(point[0]), float(point[1]))
                    for point in candidate.corners
                ],
                model_confidence=confidence,
                min_auto_accept_confidence=0.55,
                touches_frame_edge=candidate.frame_touch_count > 0,
            )
        )
    return proposals


def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    res = 0
    shift = 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        res |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return res, pos
        shift += 7
    raise ValueError("Truncated varint")


def _skip_field(buf: bytes, pos: int, wire: int) -> int:
    if wire == 0:
        _, pos = _read_varint(buf, pos)
        return pos
    if wire == 1:
        return pos + 8
    if wire == 2:
        ln, pos = _read_varint(buf, pos)
        return pos + ln
    if wire == 5:
        return pos + 4
    raise ValueError(f"Unsupported wire {wire}")


def _parse_tensor_raw(buf: bytes) -> tuple[str, np.ndarray]:
    pos = 0
    dims: list[int] = []
    dtype = 1
    name = ""
    raw = b""
    floats: list[float] = []
    while pos < len(buf):
        tag, pos = _read_varint(buf, pos)
        field, wire = tag >> 3, tag & 7
        if field == 1:
            if wire == 0:
                v, pos = _read_varint(buf, pos)
                dims.append(v)
            elif wire == 2:
                ln, pos = _read_varint(buf, pos)
                end = pos + ln
                while pos < end:
                    v, pos = _read_varint(buf, pos)
                    dims.append(v)
            else:
                pos = _skip_field(buf, pos, wire)
        elif field == 2 and wire == 0:
            dtype, pos = _read_varint(buf, pos)
        elif field == 4 and wire == 5:
            floats.append(struct.unpack_from("<f", buf, pos)[0])
            pos += 4
        elif field == 8 and wire == 2:
            ln, pos = _read_varint(buf, pos)
            name = buf[pos : pos + ln].decode("utf-8")
            pos += ln
        elif field == 9 and wire == 2:
            ln, pos = _read_varint(buf, pos)
            raw = buf[pos : pos + ln]
            pos += ln
        else:
            pos = _skip_field(buf, pos, wire)
    assert dtype == 1, f"Expected FLOAT(1), got {dtype}"
    arr = np.frombuffer(raw, dtype="<f4").copy() if raw else np.array(floats, dtype=np.float32)
    return name, arr.reshape(dims) if dims else arr.reshape(())


def _parse_onnx_graph_raw(model_bytes: bytes) -> tuple[dict[str, np.ndarray], list[tuple]]:
    """Exact mirror of `_ProtoReader` + `_parseGraph` in `lib/imaging/onnx_lite_runtime.dart`."""
    pos = 0
    graph_bytes = b""
    while pos < len(model_bytes):
        tag, pos = _read_varint(model_bytes, pos)
        field, wire = tag >> 3, tag & 7
        if field == 7 and wire == 2:
            ln, pos = _read_varint(model_bytes, pos)
            graph_bytes = model_bytes[pos : pos + ln]
            pos += ln
        else:
            pos = _skip_field(model_bytes, pos, wire)

    inits: dict[str, np.ndarray] = {}
    nodes: list[tuple] = []
    pos = 0
    while pos < len(graph_bytes):
        tag, pos = _read_varint(graph_bytes, pos)
        field, wire = tag >> 3, tag & 7
        if field == 5 and wire == 2:
            ln, pos = _read_varint(graph_bytes, pos)
            nm, t = _parse_tensor_raw(graph_bytes[pos : pos + ln])
            inits[nm] = t
            pos += ln
        elif field == 1 and wire == 2:
            ln, pos = _read_varint(graph_bytes, pos)
            nb = graph_bytes[pos : pos + ln]
            pos += ln
            npos = 0
            ins, outs, op, attrs = [], [], "", {}
            while npos < len(nb):
                ntag, npos = _read_varint(nb, npos)
                nf, nw = ntag >> 3, ntag & 7
                if nf == 1 and nw == 2:
                    aln, npos = _read_varint(nb, npos)
                    ins.append(nb[npos : npos + aln].decode("utf-8"))
                    npos += aln
                elif nf == 2 and nw == 2:
                    aln, npos = _read_varint(nb, npos)
                    outs.append(nb[npos : npos + aln].decode("utf-8"))
                    npos += aln
                elif nf == 4 and nw == 2:
                    aln, npos = _read_varint(nb, npos)
                    op = nb[npos : npos + aln].decode("utf-8")
                    npos += aln
                elif nf == 5 and nw == 2:
                    aln, npos = _read_varint(nb, npos)
                    ab = nb[npos : npos + aln]
                    npos += aln
                    apos = 0
                    aname, af, ai, astr, atens, aints = "", 0.0, 0, "", None, []
                    while apos < len(ab):
                        atag, apos = _read_varint(ab, apos)
                        afield, awire = atag >> 3, atag & 7
                        if afield == 1 and awire == 2:
                            sln, apos = _read_varint(ab, apos)
                            aname = ab[apos : apos + sln].decode("utf-8")
                            apos += sln
                        elif afield == 2 and awire == 5:
                            af = struct.unpack_from("<f", ab, apos)[0]
                            apos += 4
                        elif afield == 3 and awire == 0:
                            ai, apos = _read_varint(ab, apos)
                        elif afield == 4 and awire == 2:
                            sln, apos = _read_varint(ab, apos)
                            astr = ab[apos : apos + sln].decode("utf-8")
                            apos += sln
                        elif afield == 5 and awire == 2:
                            sln, apos = _read_varint(ab, apos)
                            _, atens = _parse_tensor_raw(ab[apos : apos + sln])
                            apos += sln
                        elif afield == 8:
                            if awire == 0:
                                iv, apos = _read_varint(ab, apos)
                                aints.append(iv)
                            elif awire == 2:
                                sln, apos = _read_varint(ab, apos)
                                send = apos + sln
                                while apos < send:
                                    iv, apos = _read_varint(ab, apos)
                                    aints.append(iv)
                            else:
                                apos = _skip_field(ab, apos, awire)
                        else:
                            apos = _skip_field(ab, apos, awire)
                    attrs[aname] = (af, ai, astr, atens, aints)
                else:
                    npos = _skip_field(nb, npos, nw)
            nodes.append((op, ins, outs, attrs))
        else:
            pos = _skip_field(graph_bytes, pos, wire)
    return inits, nodes


class ScanIdAiPipelineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        manifest_path = REPO_ROOT / "assets" / "models" / "MODEL_MANIFEST.json"
        cls.manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        cls.s1_path = REPO_ROOT / cls.manifest["models"]["stage1_detector"]["file"]
        cls.s2_path = REPO_ROOT / cls.manifest["models"]["stage2_corner_refiner"]["file"]
        cls.thresholds = FrozenThresholds(**cls.manifest["frozen_thresholds"])
        cls.detector = TwoStageOnnxDetector(str(cls.s1_path), str(cls.s2_path), cls.thresholds)
        cls.bg_pools = load_disjoint_background_pools()
        cls.spec_pools = load_disjoint_specimen_pools()

    def test_01_manifest_and_sha256_integrity(self) -> None:
        self.assertEqual(self.manifest["bundle_id"], "scanid-docnet-v1")
        self.assertEqual(self.manifest["license"], "MIT")
        self.assertTrue(self.manifest["training_provenance"]["clean_room_from_scratch"])
        self.assertFalse(self.manifest["training_provenance"]["external_pretrained_weights_used"])

        s1_bytes = self.s1_path.read_bytes()
        s2_bytes = self.s2_path.read_bytes()
        self.assertEqual(hashlib.sha256(s1_bytes).hexdigest(), self.manifest["models"]["stage1_detector"]["sha256"])
        self.assertEqual(hashlib.sha256(s2_bytes).hexdigest(), self.manifest["models"]["stage2_corner_refiner"]["sha256"])
        self.assertLess(len(s1_bytes) + len(s2_bytes), 2_000_000)

    def test_02_raw_protobuf_parser_matches_onnx_models(self) -> None:
        """Verifies the exact wire-tag parser ported to `onnx_lite_runtime.dart`."""
        for p, expected_inits in [(self.s1_path, 82), (self.s2_path, 88)]:
            inits, nodes = _parse_onnx_graph_raw(p.read_bytes())
            self.assertEqual(len(inits), expected_inits)
            self.assertGreater(len(nodes), 30)
            allowed = {"Conv", "Relu", "Add", "Mul", "Concat", "Resize", "ReduceMean", "Gemm", "Sigmoid", "Tanh", "Constant"}
            for op, _, _, _ in nodes:
                self.assertIn(op, allowed)

    def test_03_golden_vectors_match_deterministic_inference(self) -> None:
        golden_path = REPO_ROOT / "test" / "fixtures" / "ai_golden_vectors.json"
        golden = json.loads(golden_path.read_text(encoding="utf-8"))

        bg = np.full((240, 320, 3), 42, dtype=np.uint8)
        card_pts = np.array([[56, 44], [262, 52], [254, 194], [48, 184]], dtype=np.int32)
        cv2.fillConvexPoly(bg, card_pts, (238, 240, 235))
        cv2.polylines(bg, [card_pts.reshape(-1, 1, 2)], True, (180, 185, 190), 2)
        cv2.rectangle(bg, (74, 72), (122, 134), (90, 115, 155), -1)
        for k in range(5):
            cv2.line(bg, (136, 78 + k * 18), (236, 82 + k * 18), (60, 65, 70), 2)

        inp1 = bilinear_resize_rgb_to_chw(bg, 160, 160)
        d1, s1 = self.detector.s1.run(None, {"input": inp1})
        np.testing.assert_allclose(s1[0], golden["stage1_scene_prob"], atol=1e-5)

        res = self.detector.detect(bg)
        self.assertEqual(len(res.candidates), 1)
        self.assertEqual(res.candidates[0].verdict, "accepted")
        np.testing.assert_allclose(
            res.candidates[0].corners,
            np.array(golden["end_to_end_candidates"][0]["corners"], dtype=np.float32),
            atol=1e-5,
        )

    def test_04_negative_and_truncated_scenes_prevent_false_crops(self) -> None:
        rng = np.random.default_rng(12345)
        for i in range(6):
            neg = render_procedural_background(rng, 640, 480, self.bg_pools["test"])
            res = self.detector.detect(neg)
            accepted = [c for c in res.candidates if c.verdict == "accepted"]
            self.assertEqual(len(accepted), 0, f"False accept on negative {i}")

        sp = CATALOG_SPECS[0]
        bg = render_procedural_background(rng, 640, 480, self.bg_pools["test"])
        tex, al = render_specimen_card_texture(
            rng, sp[0], sp[1], sp[2], float(bg.mean()), self.spec_pools["test"]
        )
        q_trunc = sample_quad_homography(
            rng, sp[1], 640, 480, (0.40, 0.70), force_truncated=True
        )
        trunc_scene = warp_card_onto_scene(bg, tex, al, q_trunc, rng)
        res_t = self.detector.detect(trunc_scene)

        # A previous Python environment emitted a raw accepted verdict at about
        # 0.78006 for this same seed; the current one emits needsReview. That
        # model-level label is a proposal, not crop permission. Pin the final
        # production arbitration invariant instead of its runtime-sensitive score.
        trunc_proposals = _boundary_proposals_from_detection(res_t)
        trunc_final = boundary_mirror.arbitrate_single_boundary(
            trunc_scene,
            trunc_proposals[0] if trunc_proposals else None,
            extra_ai=trunc_proposals[1:],
            has_learned_model=True,
        )
        trunc_decision = (
            boundary_mirror.verify_boundary(trunc_final, 640, 480)
            if trunc_final is not None
            else None
        )
        self.assertNotEqual(
            trunc_decision.kind if trunc_decision is not None else None,
            "accepted",
            "A truncated scene must not become an authorized crop after arbitration",
        )

        # Also keep a byte-stable clipped card case so this safety property is
        # checked independently of procedural-renderer/library variation.
        golden_truncated = np.asarray(
            Image.open(REPO_ROOT / "test/fixtures/ai_golden_truncated.png").convert(
                "RGB"
            ),
            dtype=np.uint8,
        )
        golden_result = self.detector.detect(golden_truncated)
        golden_proposals = _boundary_proposals_from_detection(golden_result)
        golden_final = boundary_mirror.arbitrate_single_boundary(
            golden_truncated,
            golden_proposals[0] if golden_proposals else None,
            extra_ai=golden_proposals[1:],
            has_learned_model=True,
        )
        golden_decision = (
            boundary_mirror.verify_boundary(
                golden_final, golden_truncated.shape[1], golden_truncated.shape[0]
            )
            if golden_final is not None
            else None
        )
        self.assertIsNotNone(golden_decision)
        self.assertEqual(golden_decision.kind, "needsReview")

    def test_05_tilted_cards_multi_seed_hybrid_geometry(self) -> None:
        """Keep the original 101/303/404 procedural tilt set in the gate.

        Its old raw-IoU assertion (< 0.90) encoded a historical model defect,
        rather than a quality/safety requirement. With the frozen model and the
        current deterministic renderer, the measured raw mean is 0.939539 and
        all three cases exceed 0.90. Preserve the 0.90 bar as a positive floor
        here; the separate byte-stable seed-101 regression below still exercises
        a genuine low-IoU corner jump and verifies production arbitration.
        """
        sw, sh = 640, 480
        raw_model_ious: list[float] = []
        final_boundary_ious: list[float] = []
        bbox_ious: list[float] = []
        decisions: list[str] = []
        expected_decisions = {
            101: "accepted",
            303: "accepted",
            404: "needsReview",
        }
        for seed in (101, 303, 404):
            rng = np.random.default_rng(seed)
            bg = render_procedural_background(rng, sw, sh, self.bg_pools["test"])
            sp = CATALOG_SPECS[0]
            tex, al = render_specimen_card_texture(
                rng,
                sp[0],
                sp[1],
                sp[2],
                float(bg.mean()),
                self.spec_pools["test"],
            )
            rad = math.radians(34.0)
            cw_c, ch_c = 260.0, 164.0
            base = np.array(
                [
                    [-cw_c / 2, -ch_c / 2],
                    [cw_c / 2, -ch_c / 2],
                    [cw_c / 2, ch_c / 2],
                    [-cw_c / 2, ch_c / 2],
                ],
                dtype=np.float32,
            )
            rot = np.array(
                [[math.cos(rad), -math.sin(rad)], [math.sin(rad), math.cos(rad)]],
                dtype=np.float32,
            )
            q_px = canonicalize_quad_clockwise_tl(
                base @ rot.T + np.array([320.0, 240.0], dtype=np.float32)
            )
            scene = warp_card_onto_scene(bg, tex, al, q_px, rng)
            gt_n = q_px / np.array([sw - 1.0, sh - 1.0], dtype=np.float32)
            xs, ys = gt_n[:, 0], gt_n[:, 1]
            axis_bbox = np.array(
                [
                    [xs.min(), ys.min()],
                    [xs.max(), ys.min()],
                    [xs.max(), ys.max()],
                    [xs.min(), ys.max()],
                ],
                dtype=np.float32,
            )
            bbox_ious.append(polygon_iou(gt_n, axis_bbox))

            result = self.detector.detect(scene)
            self.assertGreaterEqual(len(result.candidates), 1)
            raw_iou = max(
                polygon_iou(gt_n, candidate.corners)
                for candidate in result.candidates
            )
            raw_model_ious.append(raw_iou)

            # Use the same gate confidence and region policy as
            # AiQuadProposal.toBoundaryProposal(): no geom_confidence substitute
            # and no implicit measured region in the single-boundary path.
            proposals = _boundary_proposals_from_detection(result)
            final = boundary_mirror.arbitrate_single_boundary(
                scene,
                proposals[0],
                extra_ai=proposals[1:],
                has_learned_model=True,
            )
            self.assertIsNotNone(final)
            self.assertIsNotNone(final.corners)
            decision = boundary_mirror.verify_boundary(final, sw, sh)
            self.assertEqual(decision.kind, expected_decisions[seed])
            final_iou = polygon_iou(
                gt_n, np.asarray(final.corners, dtype=np.float32)
            )
            final_boundary_ious.append(final_iou)
            decisions.append(decision.kind)

        # These thresholds are specific to the controlled 34-degree tilted
        # synthetic set; they are not generalized to arbitrary documents.
        self.assertGreater(min(raw_model_ious), 0.90)
        self.assertGreater(float(np.mean(final_boundary_ious)), 0.95)
        self.assertGreater(min(final_boundary_ious), 0.90)
        self.assertEqual(decisions.count("needsReview"), 1)
        self.assertEqual(decisions.count("accepted"), 2)
        self.assertLess(float(np.mean(bbox_ious)), 0.62)

    def test_06_tilted_seed_101_model_corner_jump_is_reviewed(self) -> None:
        # This checked-in synthetic fixture is reproducible across Python/OpenCV
        # environments and mirrors the production Dart regression test. The
        # threshold is specific to this observed failure; it is not a global IoU
        # requirement for documents or for accepted boundaries.
        sw, sh = 640, 480
        fixture_path = REPO_ROOT / "test/fixtures/ai_tilted_seed_101.png"
        scene = np.asarray(Image.open(fixture_path).convert("RGB"), dtype=np.uint8)
        self.assertEqual(scene.shape[:2], (sh, sw))
        gt = np.asarray(
            [
                [0.4038794339, 0.2073566914],
                [0.7412029505, 0.5108851790],
                [0.5976855159, 0.7947310209],
                [0.2603619695, 0.4912025332],
            ],
            dtype=np.float32,
        )

        result = self.detector.detect(scene)
        self.assertFalse(result.multi)
        self.assertGreaterEqual(len(result.candidates), 1)
        raw = max(result.candidates, key=lambda c: polygon_iou(gt, c.corners))
        raw_iou = polygon_iou(gt, raw.corners)
        self.assertEqual(raw.verdict, "accepted")
        self.assertGreaterEqual(raw.confidence, 0.55)
        self.assertLess(raw_iou, 0.82)

        raw_physics = boundary_mirror.measure_quad_physics(
            scene, [(float(p[0]), float(p[1])) for p in raw.corners]
        )
        self.assertLess(raw_physics["min_all_step"], 35.0)
        classical = boundary_mirror.detect_document_corners_scored(scene)
        self.assertIsNotNone(classical)
        classical_iou = polygon_iou(gt, np.asarray(classical.corners, dtype=np.float32))
        self.assertGreater(classical_iou, 0.95)

        proposals = _boundary_proposals_from_detection(result)
        final = boundary_mirror.arbitrate_single_boundary(
            scene,
            proposals[0] if proposals else None,
            extra_ai=proposals[1:],
            has_learned_model=True,
        )
        self.assertIsNotNone(final)
        self.assertEqual(final.producer, "wholeFrameDetector")
        self.assertEqual(final.model_confidence, 0.0)
        self.assertIsNotNone(final.corners)
        decision = boundary_mirror.verify_boundary(final, sw, sh)
        self.assertEqual(decision.kind, "needsReview")
        final_iou = polygon_iou(gt, np.asarray(final.corners, dtype=np.float32))
        self.assertGreater(final_iou, 0.95)
        self.assertGreater(final_iou, raw_iou + 0.15)

        xs, ys = gt[:, 0], gt[:, 1]
        axis_bbox = np.asarray(
            [
                [xs.min(), ys.min()],
                [xs.max(), ys.min()],
                [xs.max(), ys.max()],
                [xs.min(), ys.max()],
            ],
            dtype=np.float32,
        )
        self.assertLess(polygon_iou(gt, axis_bbox), 0.62)

    def test_07_multi_card_scene_separates_cards_without_merging(self) -> None:
        rng = np.random.default_rng(99887)
        sw, sh = 640, 480
        scene = render_procedural_background(rng, sw, sh, self.bg_pools["test"])
        bg_l = float(scene.mean())
        q1 = np.array([[45, 70], [275, 82], [268, 225], [38, 212]], dtype=np.float32)
        q2 = np.array([[355, 235], [595, 220], [604, 372], [364, 386]], dtype=np.float32)
        for q_px in (q1, q2):
            sp = CATALOG_SPECS[0]
            tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, self.spec_pools["test"])
            scene = warp_card_onto_scene(scene, tex, al, q_px, rng)

        res = self.detector.detect(scene)
        self.assertTrue(res.multi)
        self.assertEqual(len(res.candidates), 2)
        for q_px in (q1, q2):
            gt_n = q_px / np.array([sw - 1.0, sh - 1.0], dtype=np.float32)
            biou = max(polygon_iou(gt_n, c.corners) for c in res.candidates)
            self.assertGreater(biou, 0.90)

    def test_08_report_and_manifest_single_source_of_truth_sync(self) -> None:
        """Guarantees AI_DOCUMENT_BOUNDARY_STAGE_2026-10-22.md matches the JSON
        single source of truth byte-for-byte with zero manual drift."""
        from tool.ai.generate_benchmark_report import (
            BENCH_JSON_PATH,
            MANIFEST_PATH,
            REPORT_MD_PATH,
            render_report_markdown,
        )

        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        bench = json.loads(BENCH_JSON_PATH.read_text(encoding="utf-8"))
        self.assertEqual(manifest["training_provenance"], bench["training_provenance"])
        self.assertEqual(manifest["frozen_thresholds"], bench["frozen_thresholds_used"])
        self.assertFalse(bench["thresholds_modified_on_test"])
        self.assertTrue(bench["evaluation_environment"]["flutter_dart_runtime_executed"])
        self.assertTrue(bench["latency_benchmark"]["dart_onnx_lite_runtime"]["measured_on_ci_dart_vm_linux_x64"])
        self.assertFalse(bench["latency_benchmark"]["dart_onnx_lite_runtime"]["measured_on_physical_android_arm64"])

        expected_md = render_report_markdown(manifest, bench)
        actual_md = REPORT_MD_PATH.read_text(encoding="utf-8")
        self.assertEqual(actual_md, expected_md)

    def test_09_golden_png_lossless_parity(self) -> None:
        """Verifies test/fixtures/ai_golden_card.png matches ai_golden_vectors.json."""
        from PIL import Image

        golden = json.loads((REPO_ROOT / "test" / "fixtures" / "ai_golden_vectors.json").read_text(encoding="utf-8"))
        png_rgb = np.asarray(Image.open(REPO_ROOT / "test" / "fixtures" / "ai_golden_card.png").convert("RGB"), dtype=np.uint8)
        self.assertEqual(list(png_rgb.shape), golden["scene_shape"])

        inp1 = bilinear_resize_rgb_to_chw(png_rgb, 160, 160)
        d1, s1 = self.detector.s1.run(None, {"input": inp1})
        np.testing.assert_allclose(s1[0], golden["stage1_scene_prob"], atol=1e-5)

        res = self.detector.detect(png_rgb)
        self.assertEqual(len(res.candidates), 1)
        np.testing.assert_allclose(
            res.candidates[0].corners,
            np.array(golden["end_to_end_candidates"][0]["corners"], dtype=np.float32),
            atol=1e-5,
        )
        self.assertAlmostEqual(
            res.candidates[0].confidence,
            float(golden["end_to_end_candidates"][0]["confidence"]),
            places=5,
        )

    def test_10_frame_border_and_structural_nms_regressions(self) -> None:
        """Verifies Stage-2 0.016 border quantization margin, near-border weak-edge
        truncation gate, and outer-document vs inner-table-box structural NMS."""
        from PIL import Image
        from tool.ai.inference_pipeline import count_frame_touches

        q_grid63 = np.array(
            [[0.12, 0.14], [0.88, 0.15], [0.9859, 0.82], [0.11, 0.81]],
            dtype=np.float32,
        )
        self.assertGreater(count_frame_touches(q_grid63), 0)

        q_near_top = np.array(
            [[0.18, 0.022], [0.82, 0.024], [0.84, 0.78], [0.16, 0.76]],
            dtype=np.float32,
        )
        self.assertEqual(count_frame_touches(q_near_top, [0.22, 0.89, 0.91, 0.87]), 1)
        self.assertEqual(count_frame_touches(q_near_top, [0.86, 0.89, 0.91, 0.87]), 0)

        inner_png = np.asarray(
            Image.open(REPO_ROOT / "test" / "fixtures" / "ai_golden_inner_box.png").convert("RGB"),
            dtype=np.uint8,
        )
        res_inner = self.detector.detect(inner_png)
        self.assertEqual(len(res_inner.candidates), 1)
        outer_gt = np.array(
            [[38 / 319.0, 26 / 239.0], [282 / 319.0, 30 / 239.0], [276 / 319.0, 214 / 239.0], [32 / 319.0, 210 / 239.0]],
            dtype=np.float32,
        )
        self.assertGreater(polygon_iou(outer_gt, res_inner.candidates[0].corners), 0.95)

    def test_11_mandatory_heldout_regression_invariants(self) -> None:
        """Verifies wild_pos_jscanify_test3 and jscanify_test7_truncated remain
        untouched in Track A and Track B achieves 0/60 safety false accepts."""
        bench = json.loads(
            (REPO_ROOT / "docs" / "reports" / "ai_boundary_benchmark_2026-10-22.json").read_text(encoding="utf-8")
        )
        ledger = {row["scene_id"]: row for row in bench["track_a_wild_camera"]["scene_ledger"]}
        self.assertIn("wild_pos_jscanify_test3", ledger)
        self.assertIn("jscanify_test7_truncated", ledger)
        # Pure negatives (6) + fullbleed (1) + test8 (1) must all have 0 AI false accepts
        for sid, row in ledger.items():
            if sid not in ("wild_pos_jscanify_test3", "jscanify_test7_truncated"):
                self.assertEqual(row["ai_false_accepts"], 0, f"Unexpected Track A false accept on {sid}")
        # Track B 60 safety scenes (pure_neg + hard_shadow_neg + truncated) must have 0% false accept
        self.assertEqual(
            bench["track_b_heldout_stress"]["scanid_docnet_v1_ai"]["negative_and_truncated_false_accept_rate"],
            0.0,
        )
        self.assertLessEqual(
            bench["track_b_heldout_stress"]["scanid_docnet_v1_ai"]["false_crop_accept_count"],
            4,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
