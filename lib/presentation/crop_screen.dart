import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/contracts.dart';
import '../application/project_service.dart';
import '../domain/crop_draft.dart';
import '../domain/edit_history.dart';
import '../domain/geometry.dart';
import '../domain/image_adjustments.dart';
import '../domain/project.dart';
import 'shared.dart';

class CropScreen extends StatefulWidget {
  const CropScreen({
    required this.project,
    required this.asset,
    required this.service,
    super.key,
  });
  final Project project;
  final ImageAsset asset;
  final ProjectService service;
  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  final _canvasKey = GlobalKey();
  final _view = TransformationController();
  EditorSource? _source;
  EditHistory<CropDraft>? _history;
  CropDraft? _draft;
  Uint8List? _preview;
  String? _error;
  bool _busy = true;
  bool _showResult = false;
  bool _dirty = false;
  ImageEditor get _editor => widget.service.imageEditor!;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final source = await _editor.open(widget.asset);
      if (!mounted) {
        return;
      }
      final crop = widget.asset.crop;
      final initial = crop == null
          ? CropDraft.fullImage()
          : CropDraft(
              corners: crop.corners,
              adjustments: widget.asset.adjustments,
              aspectRatio: crop.outputWidth / crop.outputHeight,
              preservedGeometry: crop,
            );
      setState(() {
        _source = source;
        _history = EditHistory(initial);
        _draft = initial;
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userError(error);
          _busy = false;
        });
      }
    }
  }

  void _change(CropDraft next) {
    _history!.record(next);
    setState(() {
      _draft = next;
      _preview = null;
      _showResult = false;
      _dirty = true;
      _error = null;
    });
  }

  void _undo(bool redo) {
    final next = redo ? _history!.redo() : _history!.undo();
    setState(() {
      _draft = next;
      _preview = null;
      _showResult = false;
      _dirty = true;
      _error = null;
    });
  }

  ImageEditRecipe _recipe() =>
      _draft!.toRecipe(_source!.width, _source!.height);

  Future<void> _suggest() async {
    setState(() => _busy = true);
    try {
      final points = await _editor.suggest(_source!.preview);
      if (!mounted) {
        return;
      }
      if (points == null) {
        showMessage(
          context,
          'لم نجد حدوداً موثوقة. حرّك الزوايا يدوياً؛ لم تتغير الصورة.',
        );
      } else {
        _change(
          CropDraft(
            corners: points,
            adjustments: _draft!.adjustments,
            aspectRatio: _draft!.aspectRatio,
          ),
        );
        showMessage(
          context,
          'اقتراح فقط: راجع الزوايا وعدّلها أو تراجع عنه قبل المعاينة.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _render() async {
    setState(() => _busy = true);
    try {
      final recipe = _recipe();
      final bytes = await _editor.preview(widget.asset, recipe);
      if (mounted) {
        setState(() {
          _preview = bytes;
          _showResult = true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _accept() async {
    if (_preview == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await widget.service.applyCrop(
        widget.project,
        widget.asset,
        _recipe(),
      );
      if (mounted) {
        Navigator.pop(context, saved);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userError(error);
          _busy = false;
        });
      }
    }
  }

  Future<void> _leave() async {
    if (_busy) {
      return;
    }
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء تعديلات القص؟'),
        content: const Text(
          'لم تُحفظ التعديلات بعد. سيبقى الأصل وآخر نسخة معتمدة كما هما.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('متابعة التحرير'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إلغاء التعديلات'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Project>(
    canPop: !_busy && !_dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        unawaited(_leave());
      }
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'إلغاء القص',
          onPressed: _busy ? null : _leave,
          icon: const Icon(Icons.close),
        ),
        title: const Text('قص وتصحيح المستمسك'),
        actions: [
          IconButton(
            tooltip: 'تراجع',
            onPressed: !_busy && (_history?.canUndo ?? false)
                ? () => _undo(false)
                : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'إعادة',
            onPressed: !_busy && (_history?.canRedo ?? false)
                ? () => _undo(true)
                : null,
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      body: _source == null
          ? Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error ?? 'تعذر فتح الصورة.'),
                    ),
            )
          : Column(
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 900) {
                        return Row(
                          children: [
                            Expanded(child: _imageArea()),
                            SizedBox(
                              width: 310,
                              child: SingleChildScrollView(child: _tools()),
                            ),
                          ],
                        );
                      }
                      return ListView(
                        children: [
                          SizedBox(
                            height: math.max(
                              240,
                              math.min(440, constraints.maxHeight * .52),
                            ),
                            child: _imageArea(),
                          ),
                          _tools(),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    ),
  );

  Widget _imageArea() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('الزوايا')),
            ButtonSegment(value: true, label: Text('المعاينة')),
          ],
          selected: {_showResult},
          onSelectionChanged: _busy
              ? null
              : (values) {
                  if (values.single && _preview == null) {
                    showMessage(context, 'اضغط معاينة أولاً.');
                    return;
                  }
                  setState(() => _showResult = values.single);
                },
        ),
      ),
      Expanded(
        child: _showResult && _preview != null
            ? InteractiveViewer(
                child: Center(
                  child: Image.memory(
                    _preview!,
                    key: const Key('crop-result'),
                    fit: BoxFit.contain,
                  ),
                ),
              )
            : ClipRect(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final ratio = _source!.width / _source!.height;
                      final width = math.min(
                        box.maxWidth - 40,
                        (box.maxHeight - 40) * ratio,
                      );
                      final height = width / ratio;
                      return Center(
                        child: InteractiveViewer(
                          transformationController: _view,
                          minScale: 1,
                          maxScale: 5,
                          clipBehavior: Clip.none,
                          child: SizedBox(
                            // The hit-test box includes the entire corner handles,
                            // not just the image. Clip.none alone only expands paint.
                            width: width + 40,
                            height: height + 40,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  left: 20,
                                  top: 20,
                                  width: width,
                                  height: height,
                                  child: SizedBox(
                                    key: _canvasKey,
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: Image.memory(
                                            _source!.preview,
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter: _CropPainter(
                                                _draft!.corners,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                for (var i = 0; i < 4; i++)
                                  Positioned(
                                    left: _draft!.corners[i].x * width,
                                    top: _draft!.corners[i].y * height,
                                    child: GestureDetector(
                                      key: Key('crop-corner-$i'),
                                      behavior: HitTestBehavior.opaque,
                                      onPanUpdate: _busy
                                          ? null
                                          : (details) {
                                              final render =
                                                  _canvasKey.currentContext!
                                                          .findRenderObject()!
                                                      as RenderBox;
                                              final local = render
                                                  .globalToLocal(
                                                    details.globalPosition,
                                                  );
                                              final next = _draft!.withCorner(
                                                i,
                                                Point2(
                                                  (local.dx / width)
                                                      .clamp(0, 1)
                                                      .toDouble(),
                                                  (local.dy / height)
                                                      .clamp(0, 1)
                                                      .toDouble(),
                                                ),
                                              );
                                              setState(() {
                                                _draft = next;
                                                _preview = null;
                                                _showResult = false;
                                                _dirty = true;
                                                _error = null;
                                              });
                                            },
                                      onPanEnd: _busy
                                          ? null
                                          : (_) {
                                              _change(_draft!);
                                            },
                                      onPanCancel: _busy
                                          ? null
                                          : () {
                                              setState(
                                                () =>
                                                    _draft = _history!.current,
                                              );
                                            },
                                      child: Semantics(
                                        label: 'زاوية القص ${i + 1}',
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: const Color(0xff12685e),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
    ],
  );

  Widget _tools() {
    final adjustments = _draft!.adjustments;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'حرّك الزوايا الأربع. كبّر الصورة بإصبعين أو بعجلة الفأرة. لا يتغير الأصل.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _suggest,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('اقتراح الحدود'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _change(
                    _draft!.withAdjustments(
                      ImageAdjustments(
                        brightness: adjustments.brightness,
                        contrast: adjustments.contrast,
                        quarterTurns: (adjustments.quarterTurns + 1) % 4,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.rotate_90_degrees_cw),
            label: Text('تدوير · ${adjustments.quarterTurns * 90}°'),
          ),
          const SizedBox(height: 12),
          const Text('نسبة الأبعاد (اختيارية؛ ليست قياساً فعلياً)'),
          DropdownButton<double?>(
            key: const Key('crop-aspect'),
            isExpanded: true,
            value: _draft!.aspectRatio == null
                ? null
                : ((_draft!.aspectRatio! - 85.6 / 53.98).abs() < 1e-6
                      ? 85.6 / 53.98
                      : ((_draft!.aspectRatio! - 210 / 297).abs() < 1e-6
                            ? 210 / 297
                            : ((_draft!.aspectRatio! - 1).abs() < 1e-6
                                  ? 1
                                  : -1))),
            items: const [
              DropdownMenuItem(value: null, child: Text('تقدير من الزوايا')),
              DropdownMenuItem(
                value: 85.6 / 53.98,
                child: Text('نسبة بطاقة 85.6 : 53.98'),
              ),
              DropdownMenuItem(value: 210 / 297, child: Text('نسبة A4 عمودي')),
              DropdownMenuItem(value: 1, child: Text('مربع')),
              DropdownMenuItem(
                value: -1,
                enabled: false,
                child: Text('النسبة المحفوظة'),
              ),
            ],
            onChanged: _busy
                ? null
                : (ratio) => _change(
                    CropDraft(
                      corners: _draft!.corners,
                      adjustments: adjustments,
                      aspectRatio: ratio,
                    ),
                  ),
          ),
          Text('الإضاءة: ${(adjustments.brightness * 100).round()}'),
          Slider(
            key: const Key('crop-brightness'),
            value: adjustments.brightness,
            min: -.5,
            max: .5,
            divisions: 20,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _draft = _draft!.withAdjustments(
                      ImageAdjustments(
                        brightness: v,
                        contrast: adjustments.contrast,
                        quarterTurns: adjustments.quarterTurns,
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          Text('التباين: ${adjustments.contrast.toStringAsFixed(2)}'),
          Slider(
            key: const Key('crop-contrast'),
            value: adjustments.contrast,
            min: .25,
            max: 3,
            divisions: 55,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _draft = _draft!.withAdjustments(
                      ImageAdjustments(
                        brightness: adjustments.brightness,
                        contrast: v,
                        quarterTurns: adjustments.quarterTurns,
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          TextButton(
            onPressed: _busy ? null : () => _change(CropDraft.fullImage()),
            child: const Text('إعادة ضبط إلى الأصل'),
          ),
          const Text(
            'راجع النصوص والوجوه قبل الاعتماد. النسبة المقدرة لا تحدد الحجم الحقيقي ولا تضمن استعادته من الصورة.',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _busy ? null : _render,
            child: const Text('معاينة التصحيح'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('accept-crop'),
            onPressed: _busy || _preview == null ? null : _accept,
            child: const Text('اعتماد القص وحفظ'),
          ),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.points);
  final List<Point2> points;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(points[0].x * size.width, points[0].y * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p.x * size.width, p.y * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xff12685e).withValues(alpha: .15),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff12685e)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      !identical(oldDelegate.points, points);
}
