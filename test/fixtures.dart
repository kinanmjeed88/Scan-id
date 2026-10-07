import 'package:scan_id/domain/project.dart';

Project projectFixture({
  String id = 'project1',
  List<ImageAsset> assets = const [],
  List<DocumentItem> items = const [],
}) => Project(
  id: id,
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 6),
  updatedAt: DateTime.utc(2026, 10, 6),
  assets: assets,
  items: items,
);

ImageAsset assetFixture({String id = 'asset1', String projectId = 'project1'}) {
  final prefix = 'projects/$projectId/assets/$id';
  return ImageAsset(
    id: id,
    name: 'بطاقة.png',
    originalPath: '$prefix/original.png',
    workingPath: '$prefix/working.png',
    thumbnailPath: '$prefix/thumb.jpg',
    width: 400,
    height: 250,
  );
}

DocumentItem itemFixture({String id = 'item1', String assetId = 'asset1'}) =>
    DocumentItem(
      id: id,
      assetId: assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      locked: true,
      sizeConfirmed: true,
    );
