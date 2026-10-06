import 'dart:isolate';
import '../domain/packing.dart';
import '../domain/project.dart';

Future<PackingProposal> createPackingProposal(
  Project project, {
  required bool includeLocked,
  required bool allowRotation,
  required int pageIndex,
}) => Isolate.run(
  () => proposePacking(
    project,
    includeLocked: includeLocked,
    allowRotation: allowRotation,
    pageIndex: pageIndex,
  ),
);

typedef PackingProposer =
    Future<PackingProposal> Function(
      Project project, {
      required bool includeLocked,
      required bool allowRotation,
      required int pageIndex,
    });
