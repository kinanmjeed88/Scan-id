import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/ai_document_detector.dart';
import 'package:scan_id/imaging/onnx_lite_runtime.dart';
import 'package:scan_id/imaging/prepare_image.dart';

AiModelBundle _loadBundleFromRepo() {
  final manifestJson = File(
    'assets/models/MODEL_MANIFEST.json',
  ).readAsStringSync();
  final s1 = File('assets/models/scanid_stage1_det_v1.onnx').readAsBytesSync();
  final s2 = File(
    'assets/models/scanid_stage2_corners_v1.onnx',
  ).readAsBytesSync();
  return AiModelBundle.verified(
    manifestJson: manifestJson,
    stage1Bytes: s1,
    stage2Bytes: s2,
  );
}

Uint8List _rgbFromDecoded(img.Image image) {
  final out = Uint8List(image.width * image.height * 3);
  var k = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      out[k++] = p.r.toInt().clamp(0, 255);
      out[k++] = p.g.toInt().clamp(0, 255);
      out[k++] = p.b.toInt().clamp(0, 255);
    }
  }
  return out;
}

double _percentile(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}

void main() {
  group('AiModelBundle & OnnxLiteSession', () {
    test(
      'verifies SHA-256 manifest, sizes, and rejects tampered ONNX bytes',
      () {
        final manifestJson = File(
          'assets/models/MODEL_MANIFEST.json',
        ).readAsStringSync();
        final s1 = File(
          'assets/models/scanid_stage1_det_v1.onnx',
        ).readAsBytesSync();
        final s2 = File(
          'assets/models/scanid_stage2_corners_v1.onnx',
        ).readAsBytesSync();

        expect(s1.length, 498075);
        expect(s2.length, 608568);

        final bundle = AiModelBundle.verified(
          manifestJson: manifestJson,
          stage1Bytes: s1,
          stage2Bytes: s2,
        );
        expect(bundle.bundleId, 'scanid-docnet-v1');
        expect(bundle.thresholds.acceptRoiValid, closeTo(0.65, 1e-6));

        final tamperedS1 = Uint8List.fromList(s1);
        tamperedS1[tamperedS1.length - 1] ^= 0xFF;
        expect(
          () => AiModelBundle.verified(
            manifestJson: manifestJson,
            stage1Bytes: tamperedS1,
            stage2Bytes: s2,
          ),
          throwsFormatException,
        );

        final tamperedS2 = Uint8List.fromList(s2);
        tamperedS2[0] ^= 0x01;
        expect(
          () => AiModelBundle.verified(
            manifestJson: manifestJson,
            stage1Bytes: s1,
            stage2Bytes: tamperedS2,
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'executes Stage-1 and Stage-2 ONNX graphs and validates input shapes',
      () {
        final bundle = _loadBundleFromRepo();
        final s1 = OnnxLiteSession.fromBytes(bundle.stage1Bytes);
        final s2 = OnnxLiteSession.fromBytes(bundle.stage2Bytes);

        final out1 = s1.run({
          'input': OnnxTensor(const [
            1,
            3,
            160,
            160,
          ], Float32List(3 * 160 * 160)),
        });
        expect(out1['dense_map']!.shape, const [1, 7, 40, 40]);
        expect(out1['scene_prob']!.shape, const [1, 2]);

        final out2 = s2.run({
          'input': OnnxTensor(const [
            1,
            3,
            128,
            128,
          ], Float32List(3 * 128 * 128)),
        });
        expect(out2['corner_heatmaps']!.shape, const [1, 6, 64, 64]);
        expect(out2['corner_offsets']!.shape, const [1, 2, 64, 64]);
        expect(out2['roi_quality']!.shape, const [1, 3]);

        expect(() => s1.run(const {}), throwsArgumentError);
        expect(
          () => s1.run({
            'input': OnnxTensor(const [1, 3, 80, 80], Float32List(3 * 80 * 80)),
          }),
          throwsFormatException,
        );
      },
    );

    test(
      'matches ONNX Runtime golden parity (<1e-5 tensors, <1e-3 multi-scene post-processing)',
      () {
        final golden =
            jsonDecode(
                  File(
                    'test/fixtures/ai_golden_vectors.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final pngBytes = File(
          'test/fixtures/ai_golden_card.png',
        ).readAsBytesSync();
        final decoded = decodeForProcessing(pngBytes);
        expect([decoded.height, decoded.width], [240, 320]);
        final rgb = _rgbFromDecoded(decoded);

        final bundle = _loadBundleFromRepo();
        final detector = AiDocumentDetector.fromBundle(bundle);

        // 1. Stage-1 tensor-level parity against ONNX Runtime (<1e-5)
        final inp1 = resampleRoiToChw(
          rgb,
          decoded.width,
          decoded.height,
          160,
          160,
        );
        final out1 = detector.stage1Session.run({'input': inp1});
        final sProb = out1['scene_prob']!.data;
        final expectedSProb = golden['stage1_scene_prob'] as List<Object?>;
        expect(sProb[0], closeTo((expectedSProb[0] as num).toDouble(), 1e-5));
        expect(sProb[1], closeTo((expectedSProb[1] as num).toDouble(), 1e-5));

        final dMap = out1['dense_map']!.data;
        for (final cellObj
            in (golden['stage1_dense_sample_cells'] as List<Object?>)) {
          final cell = cellObj as Map<String, Object?>;
          final c = cell['c'] as int;
          final y = cell['y'] as int;
          final x = cell['x'] as int;
          final val = (cell['val'] as num).toDouble();
          expect(dMap[c * 1600 + y * 40 + x], closeTo(val, 1e-5));
        }

        // 2. Stage-2 tensor-level parity against ONNX Runtime (<1e-5)
        final roiBox = (golden['stage2_roi_box'] as List<Object?>)
            .map((e) => (e as num).toDouble())
            .toList();
        final inp2 = resampleRoiToChw(
          rgb,
          decoded.width,
          decoded.height,
          128,
          128,
          rx0: roiBox[0],
          ry0: roiBox[1],
          rx1: roiBox[2],
          ry1: roiBox[3],
        );
        final out2 = detector.stage2Session.run({'input': inp2});
        final rQual = out2['roi_quality']!.data;
        final expectedQual = golden['stage2_roi_quality'] as List<Object?>;
        for (var i = 0; i < 3; i++) {
          expect(rQual[i], closeTo((expectedQual[i] as num).toDouble(), 1e-5));
        }
        final chData = out2['corner_heatmaps']!.data;
        final expectedMaxima = golden['stage2_heatmap_maxima'] as List<Object?>;
        for (var c = 0; c < 6; c++) {
          var maxV = -1.0;
          for (var p = 0; p < 64 * 64; p++) {
            maxV = math.max(maxV, chData[c * 4096 + p]);
          }
          expect(maxV, closeTo((expectedMaxima[c] as num).toDouble(), 1e-5));
        }
        final coData = out2['corner_offsets']!.data;
        for (final cellObj
            in (golden['stage2_offset_sample_cells'] as List<Object?>)) {
          final cell = cellObj as Map<String, Object?>;
          final c = cell['c'] as int;
          final y = cell['y'] as int;
          final x = cell['x'] as int;
          final val = (cell['val'] as num).toDouble();
          expect(coData[c * 4096 + y * 64 + x], closeTo(val, 1e-5));
        }

        // 3. Multi-scene end-to-end parity across single, two-card, truncated,
        // and outer-sheet-with-inner-box golden PNGs
        final multiCases = golden['multi_scene_cases'] as List<Object?>;
        expect(multiCases, hasLength(4));
        for (final caseObj in multiCases) {
          final tc = caseObj as Map<String, Object?>;
          final name = tc['name'] as String;
          final caseBytes = File(tc['png_file'] as String).readAsBytesSync();
          final caseImg = decodeForProcessing(caseBytes);
          final caseRgb = _rgbFromDecoded(caseImg);

          final t1 = resampleRoiToChw(
            caseRgb,
            caseImg.width,
            caseImg.height,
            160,
            160,
          );
          final sp = detector.stage1Session.run({
            'input': t1,
          })['scene_prob']!.data;
          final expSp = tc['stage1_scene_prob'] as List<Object?>;
          expect(
            sp[0],
            closeTo((expSp[0] as num).toDouble(), 1e-5),
            reason: '$name scene_prob[0]',
          );
          expect(
            sp[1],
            closeTo((expSp[1] as num).toDouble(), 1e-5),
            reason: '$name scene_prob[1]',
          );

          final det = detector.detectImage(caseImg);
          expect(det.multi, tc['multi'] as bool, reason: '$name multi');
          final expCands = tc['candidates'] as List<Object?>;
          expect(
            det.candidates,
            hasLength(expCands.length),
            reason: '$name candidate count',
          );
          for (var k = 0; k < expCands.length; k++) {
            final ec = expCands[k] as Map<String, Object?>;
            final dc = det.candidates[k];
            expect(
              dc.eligibleForAutoAccept,
              (ec['verdict'] as String) == 'accepted',
              reason: '$name[$k] verdict',
            );
            expect(
              dc.frameTouchCount,
              ec['frame_touch_count'] as int,
              reason: '$name[$k] frameTouchCount',
            );
            expect(
              dc.confidence,
              closeTo((ec['confidence'] as num).toDouble(), 1e-3),
              reason: '$name[$k] confidence',
            );
            final expCorners = ec['corners'] as List<Object?>;
            for (var cIdx = 0; cIdx < 4; cIdx++) {
              final pair = expCorners[cIdx] as List<Object?>;
              expect(
                dc.corners[cIdx].x,
                closeTo((pair[0] as num).toDouble(), 1e-3),
                reason: '$name[$k] corner[$cIdx].x',
              );
              expect(
                dc.corners[cIdx].y,
                closeTo((pair[1] as num).toDouble(), 1e-3),
                reason: '$name[$k] corner[$cIdx].y',
              );
            }
          }
        }

        final proposal = suggestProposalWithAiBundle(pngBytes, bundle);
        expect(proposal, isNotNull);
        expect(proposal!.producer, BoundaryProducer.learnedModel);
      },
    );

    test(
      'pins frame-border quantization margin (0.016) and weak-border-edge truncation gate',
      () {
        // Stage-2 64x64 cell 63 quantizes near 0.9859 (1 - 0.9859 = 0.0141 <= 0.016)
        final borderQuantized = <Point2>[
          Point2(0.12, 0.14),
          Point2(0.88, 0.15),
          Point2(0.9859, 0.82),
          Point2(0.11, 0.81),
        ];
        expect(countFrameTouches(borderQuantized), greaterThan(0));

        // Near-border edge (y = 0.022 <= 0.028) with vanished top boundary support
        // while the other 3 edges have strong boundary support -> truncated!
        final nearTopTruncated = <Point2>[
          Point2(0.18, 0.022),
          Point2(0.82, 0.024),
          Point2(0.84, 0.78),
          Point2(0.16, 0.76),
        ];
        expect(
          countFrameTouches(
            nearTopTruncated,
            edges: const [0.22, 0.89, 0.91, 0.87],
          ),
          1,
        );
        // Same geometry when all 4 physical edges have real boundary support is NOT truncated
        expect(
          countFrameTouches(
            nearTopTruncated,
            edges: const [0.86, 0.89, 0.91, 0.87],
          ),
          0,
        );
      },
    );

    test('rejects non-document negative images without auto-accepting', () {
      final detector = AiDocumentDetector.fromBundle(_loadBundleFromRepo());
      final neg = img.Image(width: 480, height: 360);
      for (var y = 0; y < neg.height; y++) {
        for (var x = 0; x < neg.width; x++) {
          final v = ((x * 3 + y * 5) % 80) + 40;
          neg.setPixelRgb(x, y, v, v + 5, v + 10);
        }
      }
      final res = detector.detectBytes(Uint8List.fromList(img.encodePng(neg)));
      expect(res.candidates.where((p) => p.eligibleForAutoAccept), isEmpty);
    });

    test(
      'profiles real Dart VM OnnxLiteSession latency and process RSS at 1280x960',
      () {
        final detector = AiDocumentDetector.fromBundle(_loadBundleFromRepo());

        // Build 1280x960 single-card, two-card, and pure-negative rasters matching
        // maxRecognitionPreviewLongEdge = 1280.
        final single = img.Image(width: 1280, height: 960);
        img.fill(single, color: img.ColorRgb8(42, 45, 50));
        img.fillRect(
          single,
          x1: 210,
          y1: 185,
          x2: 1050,
          y2: 735,
          color: img.ColorRgb8(238, 240, 235),
        );
        img.fillRect(
          single,
          x1: 265,
          y1: 245,
          x2: 430,
          y2: 470,
          color: img.ColorRgb8(88, 114, 152),
        );

        final twoCards = img.Image(width: 1280, height: 960);
        img.fill(twoCards, color: img.ColorRgb8(40, 44, 48));
        for (final r in const [(90, 140, 560, 440), (690, 490, 1170, 790)]) {
          img.fillRect(
            twoCards,
            x1: r.$1,
            y1: r.$2,
            x2: r.$3,
            y2: r.$4,
            color: img.ColorRgb8(239, 241, 236),
          );
          img.fillRect(
            twoCards,
            x1: r.$1 + 36,
            y1: r.$2 + 48,
            x2: r.$1 + 140,
            y2: r.$2 + 180,
            color: img.ColorRgb8(88, 114, 152),
          );
        }

        final negative = img.Image(width: 1280, height: 960);
        for (var y = 0; y < negative.height; y++) {
          for (var x = 0; x < negative.width; x++) {
            final v = ((x * 5 + y * 3) % 70) + 45;
            negative.setPixelRgb(x, y, v, v + 4, v + 8);
          }
        }

        Map<String, Object> profileWorkload(img.Image scene, {int runs = 8}) {
          for (var w = 0; w < 2; w++) {
            detector.detectImageWithProfile(scene);
          }
          final modelMs = <double>[];
          final fullMs = <double>[];
          final s1Ms = <double>[];
          final s2Ms = <double>[];
          var lastCands = 0;
          var s2Calls = 0;
          for (var i = 0; i < runs; i++) {
            final (res, p) = detector.detectImageWithProfile(scene);
            modelMs.add(p.modelOnlyMs);
            fullMs.add(p.fullPipelineMs);
            s1Ms.add(p.stage1OnnxMs);
            s2Ms.add(p.stage2OnnxMs);
            lastCands = res.candidates.length;
            s2Calls = p.stage2Calls;
          }
          modelMs.sort();
          fullMs.sort();
          s1Ms.sort();
          s2Ms.sort();
          return <String, Object>{
            'runs': runs,
            'candidates': lastCands,
            'stage2_calls': s2Calls,
            'stage1_median_ms': double.parse(
              _percentile(s1Ms, 0.5).toStringAsFixed(2),
            ),
            'stage2_median_ms': double.parse(
              _percentile(s2Ms, 0.5).toStringAsFixed(2),
            ),
            'model_only_median_ms': double.parse(
              _percentile(modelMs, 0.5).toStringAsFixed(2),
            ),
            'model_only_p95_ms': double.parse(
              _percentile(modelMs, 0.95).toStringAsFixed(2),
            ),
            'full_pipeline_median_ms': double.parse(
              _percentile(fullMs, 0.5).toStringAsFixed(2),
            ),
            'full_pipeline_p95_ms': double.parse(
              _percentile(fullMs, 0.95).toStringAsFixed(2),
            ),
          };
        }

        final rssBeforeMb = ProcessInfo.currentRss / (1024 * 1024);
        final singleStats = profileWorkload(single);
        final twoStats = profileWorkload(twoCards);
        final negStats = profileWorkload(negative);
        final rssAfterMb = ProcessInfo.currentRss / (1024 * 1024);
        final maxRssMb = ProcessInfo.maxRss / (1024 * 1024);

        expect((singleStats['candidates'] as int), greaterThanOrEqualTo(1));
        expect((twoStats['candidates'] as int), 2);
        expect((negStats['candidates'] as int), 0);

        final metrics = <String, Object>{
          'os': Platform.operatingSystem,
          'dart_version': Platform.version.split(' ').first,
          'input_resolution': '1280x960',
          'rss_before_mb': double.parse(rssBeforeMb.toStringAsFixed(2)),
          'rss_after_mb': double.parse(rssAfterMb.toStringAsFixed(2)),
          'max_rss_mb': double.parse(maxRssMb.toStringAsFixed(2)),
          'single_card_1280x960': singleStats,
          'two_cards_1280x960': twoStats,
          'pure_negative_1280x960': negStats,
        };
        Directory('diagnostics').createSync(recursive: true);
        File('diagnostics/dart-ai-metrics.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );

        stdout.writeln(
          '::notice title=dart-ai-metrics::'
          'os=${Platform.operatingSystem} '
          'single_model_ms=${singleStats['model_only_median_ms']} '
          'single_full_ms=${singleStats['full_pipeline_median_ms']} '
          'two_model_ms=${twoStats['model_only_median_ms']} '
          'two_full_ms=${twoStats['full_pipeline_median_ms']} '
          'neg_model_ms=${negStats['model_only_median_ms']} '
          'neg_full_ms=${negStats['full_pipeline_median_ms']} '
          'rss_mb=${rssAfterMb.toStringAsFixed(1)} '
          'max_rss_mb=${maxRssMb.toStringAsFixed(1)}',
        );
      },
    );
  });
}
