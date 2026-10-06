import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../application/contracts.dart';
import '../application/output_service.dart';
import '../application/project_service.dart';
import '../domain/export_naming.dart';
import '../domain/export_plan.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import 'page_canvas.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({
    required this.project,
    required this.service,
    this.onProfile,
    this.output,
    super.key,
  });
  final Project project;
  final ProjectService service;
  final Future<void> Function(ExportProfile)? onProfile;

  /// Injected by tests; the app builds the platform service itself.
  final OutputService? output;
  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  late ExportFormat _format = widget.project.exportProfile.format;
  late int _dpi = widget.project.exportProfile.dpi;
  int _page = 0;
  bool _busy = false, _reviewed = false;
  late final OutputService _output = widget.output ?? _platformOutput();
  String? _message;
  int _first = 0;
  late int _last = widget.project.pageCount - 1;
  ExportPlan get _plan => ExportPlan(
    widget.project,
    ExportProfile(format: _format, dpi: _dpi),
    pages: [for (var i = _first; i <= _last; i++) i],
  );
  OutputService _platformOutput() =>
      OutputService.native(widget.service.assets);

  Future<void> _run(OutputTarget target) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final plan = _plan;
      await widget.onProfile?.call(plan.profile);
      final message = await _output.output(plan, target: target);
      if (mounted) setState(() => _message = message);
    } catch (e) {
      if (mounted) setState(() => _message = userError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ExportPlan? plan;
    String? invalid;
    try {
      plan = _plan;
    } catch (e) {
      invalid = userError(e);
    }
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('المعاينة النهائية والتصدير')),
        body: LayoutBuilder(
          builder: (_, available) => Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (_, box) {
                    final scale = PageViewport(
                      widget.project.paper,
                      math.max(1.0, box.maxWidth - 24),
                      math.max(1.0, box.maxHeight - 24),
                    ).scale;
                    return InteractiveViewer(
                      child: Center(
                        child: PageCanvas(
                          project: widget.project,
                          assets: widget.service.assets,
                          scale: scale,
                          pageIndex: _page,
                          showGuides: false,
                          highQuality: true,
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                height: math.min(280.0, available.maxHeight * .5),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      if (_busy) const LinearProgressIndicator(),
                      if (invalid != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(invalid),
                        ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_message!),
                        ),

                      Wrap(
                        spacing: 12,
                        children: [
                          DropdownButton<int>(
                            value: _page,
                            items: [
                              for (var i = 0; i < widget.project.pageCount; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('صفحة ${i + 1}'),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _page = v!),
                          ),
                          DropdownButton<ExportFormat>(
                            value: _format,
                            items: [
                              for (final f in ExportFormat.values)
                                DropdownMenuItem(
                                  value: f,
                                  child: Text(f.name.toUpperCase()),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _format = v!;
                                    _reviewed = false;
                                  }),
                          ),
                          DropdownButton<int>(
                            value: _dpi,
                            items: const [
                              DropdownMenuItem(
                                value: 300,
                                child: Text('300 DPI'),
                              ),
                              DropdownMenuItem(
                                value: 600,
                                child: Text('600 DPI'),
                              ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _dpi = v!;
                                    _reviewed = false;
                                  }),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 12,
                        children: [
                          DropdownButton<int>(
                            value: _first,
                            items: [
                              for (var i = 0; i < widget.project.pageCount; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('من صفحة ${i + 1}'),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _first = v!;
                                    _reviewed = false;
                                  }),
                          ),
                          DropdownButton<int>(
                            value: _last,
                            items: [
                              for (var i = 0; i < widget.project.pageCount; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('إلى صفحة ${i + 1}'),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _last = v!;
                                    _reviewed = false;
                                  }),
                          ),
                        ],
                      ),
                      const Text(
                        'تُصدّر الصفحات المختارة. JPG/PNG ملف لكل صفحة. اختر حفظاً محلياً. للطباعة استخدم A4 والحجم الفعلي 100% دون Fit to page، وتحقق بالمسطرة.',
                      ),
                      if (plan != null)
                        Text(
                          'أسماء الملفات تُشتق من اسم المشروع، مثل «${exportNames(plan!).files.first}». إن وُجد ملف بالاسم نفسه يسألك النظام قبل الاستبدال.',
                        ),
                      if (plan != null)
                        for (final warning in plan.warnings) Text(warning),
                      CheckboxListTile(
                        title: const Text(
                          'راجعت الصفحات والمقاسات وتحذيرات الجودة والعناصر غير الموضوعة',
                        ),
                        value: _reviewed,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _reviewed = v!),
                      ),
                      Wrap(
                        spacing: 12,
                        children: [
                          FilledButton(
                            onPressed: _busy || !_reviewed || plan == null
                                ? null
                                : () => _run(OutputTarget.save),
                            child: const Text('تصدير الملفات'),
                          ),
                          OutlinedButton(
                            onPressed: _busy || !_reviewed || plan == null
                                ? null
                                : () => _run(OutputTarget.print),
                            child: const Text('طباعة عبر النظام'),
                          ),
                          if (_output.shareTarget != ShareTarget.none)
                            OutlinedButton.icon(
                              key: const Key('export-share'),
                              onPressed: _busy || !_reviewed || plan == null
                                  ? null
                                  : () => _run(OutputTarget.share),
                              icon: Icon(
                                _output.shareTarget == ShareTarget.shareSheet
                                    ? Icons.ios_share
                                    : Icons.folder_open,
                              ),
                              label: Text(
                                _output.shareTarget == ShareTarget.shareSheet
                                    ? 'مشاركة الملفات'
                                    : 'فتح موقع الملفات',
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
