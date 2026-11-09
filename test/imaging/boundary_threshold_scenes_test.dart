import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/safe_files.dart';

// Synthetic pixel scenes exercise the classical fallback, NOT learned-model
// accuracy under real low light. The classical score can never authorize warp.
void main() {
  for (final scene in [
    (name: 'dark background', background: 20, card: 220),
    (name: 'low light', background: 10, card: 40),
    (name: 'similar background', background: 180, card: 190),
  ]) {
    test(
      '${scene.name}: inner frame cannot make fallback automatic at 55/60/70',
      () async {
        final image = img.Image(width: 400, height: 280);
        img.fill(
          image,
          color: img.ColorRgb8(
            scene.background,
            scene.background,
            scene.background,
          ),
        );
        img.fillRect(
          image,
          x1: 50,
          y1: 45,
          x2: 350,
          y2: 235,
          color: img.ColorRgb8(scene.card, scene.card, scene.card),
        );
        img.drawRect(
          image,
          x1: 90,
          y1: 80,
          x2: 310,
          y2: 200,
          color: img.ColorRgb8(0, 0, 0),
          thickness: 3,
        );
        final editor = LocalImageEditor(SafeFiles(Directory.systemTemp));
        final proposal = await editor.suggestProposal(
          Uint8List.fromList(img.encodePng(image)),
        );
        // No proposal is also an honest manual fallback, not invented corners.
        if (proposal == null) return;
        expect(proposal.producer, BoundaryProducer.detector);
        for (final threshold in [.55, .60, .70]) {
          expect(
            verifyBoundary(
              proposal,
              sourceWidth: 400,
              sourceHeight: 280,
              acceptanceThreshold: threshold,
            ).cropAuthorization,
            isNull,
          );
        }
      },
    );
  }
}
