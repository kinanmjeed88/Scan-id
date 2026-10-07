import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/project_service.dart';
import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import 'crop_screen.dart';
import 'editor_controller.dart';
import 'export_screen.dart';
import 'ribbon.dart';
import 'shared.dart';
import 'sheet_view.dart';
import 'shortcuts.dart';

/// The A4 editor: a Word-style ribbon over continuously scrolling pages.
class LayoutScreen extends StatefulWidget {
  const LayoutScreen({
    required this.project,
    required this.service,
    this.pickImages,
    this.intakeSummary,
    this.intakeWarnings = const [],
    this.adjustmentCommitDelay = const Duration(milliseconds: 700),
    super.key,
  });

  final Project project;
  final ProjectService service;

  /// Opens the platform image picker; null hides the import commands.
  final Future<List<ImportSource>> Function()? pickImages;
  final String? intakeSummary;
  final List<String> intakeWarnings;
  final Duration adjustmentCommitDelay;

  @override
  State<LayoutScreen> createState() => _LayoutScreenState();
}

class _LayoutScreenState extends State<LayoutScreen> {
  late final LayoutEditorController _c;
  String _tab = 'home';
  bool _intakeVisible = true;

  @override
  void initState() {
    super.initState();
    _c = LayoutEditorController(
      project: widget.project,
      service: widget.service,
      pickImages: widget.pickImages,
      adjustmentCommitDelay: widget.adjustmentCommitDelay,
    )..onMessage = (message) {
        if (mounted) showMessage(context, message);
      };
    _c.addListener(_changed);
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  String? _lastActive;

  void _changed() {
    if (!mounted) return;
    final active = _c.active;
    // Like Office, selecting a document brings up its contextual tab when
    // it still needs a category.
    if (active != null &&
        active.id != _lastActive &&
        active.documentKind == DocumentKind.unknown) {
      _tab = 'document';
    }
    if (active == null && (_tab == 'document' || _tab == 'picture')) {
      _tab = 'home';
    }
    _lastActive = active?.id;
    setState(() {});
  }

  Future<void> _leave() async {
    await _c.flush();
    if (mounted) Navigator.pop(context, _c.session.current);
  }

  // ---------------------------------------------------------------------
  // Commands that need a route or a dialog

  Future<void> _openExport() async {
    await _c.flush();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExportScreen(
          project: _c.session.current,
          service: widget.service,
          onProfile: (profile) =>
              _c.edit((p) => p.copyWith(exportProfile: profile), layout: false),
        ),
      ),
    );
  }

  Future<void> _editCrop() async {
    final item = _c.active;
    final asset = _c.activeAsset;
    if (item == null || asset == null || _c.busy) return;
    await _c.flush();
    if (!mounted) return;
    final saved = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          project: _c.session.current,
          asset: _c.session.current.assets.firstWhere((a) => a.id == asset.id),
          service: widget.service,
          documentKind: item.documentKind,
        ),
      ),
    );
    if (saved != null && mounted) await _c.adoptCrop(saved, asset.id);
  }

  Future<void> _customMargins() async {
    final m = _c.project.paper.margins;
    final input = await editMeasurements(context, 'هوامش مخصصة (مم)', {
      'أعلى': m.top,
      'يمين': m.right,
      'أسفل': m.bottom,
      'يسار': m.left,
    });
    if (input == null) return;
    await _c.setMargins(
      Margins(
        top: input['أعلى']!,
        right: input['يمين']!,
        bottom: input['أسفل']!,
        left: input['يسار']!,
      ),
    );
  }

  Future<void> _copies(int count) async {
    var n = count;
    if (n == 0) {
      final input = await editMeasurements(context, 'نسخ إضافية', {
        'عدد النسخ': 1,
      }, decimals: 0);
      if (input == null) return;
      final value = input['عدد النسخ']!;
      if (value != value.roundToDouble() || value < 1 || value > 200) {
        if (mounted) {
          showMessage(context, 'عدد النسخ يجب أن يكون عدداً صحيحاً بين 1 و200.');
        }
        return;
      }
      n = value.toInt();
    }
    await _c.addCopies(n);
  }

  Future<void> _editCatalog() async {
    final catalog = await showDialog<DocumentSizeCatalog>(
      context: context,
      builder: (_) => CatalogDialog(catalog: _c.project.catalog),
    );
    if (catalog != null) await _c.setCatalog(catalog);
  }

  List<ShortcutBinding> get _shortcuts => [
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
      keys: 'Ctrl + Z',
      description: 'تراجع',
      run: () => unawaited(_c.undo()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ),
      keys: 'Ctrl + Shift + Z',
      description: 'إعادة',
      run: () => unawaited(_c.redo()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyY, control: true),
      keys: 'Ctrl + Y',
      description: 'إعادة',
      run: () => unawaited(_c.redo()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.delete),
      keys: 'Delete',
      description: 'حذف المحدد',
      run: () => unawaited(_c.deleteSelected()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyD, control: true),
      keys: 'Ctrl + D',
      description: 'تكرار المحدد',
      run: () => unawaited(_c.duplicate()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyA, control: true),
      keys: 'Ctrl + A',
      description: 'تحديد الكل',
      run: _c.selectAll,
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyR, control: true),
      keys: 'Ctrl + R',
      description: 'تدوير المحدد 90° على الورقة',
      run: () => unawaited(_c.rotateOnSheet()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyP, control: true),
      keys: 'Ctrl + P',
      description: 'معاينة وطباعة وتصدير',
      run: () => unawaited(_openExport()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.escape),
      keys: 'Esc',
      description: 'إلغاء التحديد',
      run: _c.clearSelection,
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.equal,
        control: true,
      ),
      keys: 'Ctrl + =',
      description: 'تكبير',
      run: _c.zoomIn,
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.minus,
        control: true,
      ),
      keys: 'Ctrl + -',
      description: 'تصغير',
      run: _c.zoomOut,
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.digit0,
        control: true,
      ),
      keys: 'Ctrl + 0',
      description: 'ملاءمة عرض الصفحة',
      run: () => _c.setZoomMode(ZoomMode.pageWidth),
    ),
    const ShortcutBinding(
      activator: SingleActivator(LogicalKeyboardKey.arrowLeft),
      keys: '← → ↑ ↓',
      description: 'تحريك المحدد 1 مم (مع Shift: 10 مم) عند التركيز على الورقة',
    ),
  ];

  // ---------------------------------------------------------------------
  // Ribbon

  List<RibbonTab> _tabs() {
    final c = _c;
    final busy = c.busy;
    final item = c.active;
    final asset = c.activeAsset;
    final hasSelection = item != null;
    final project = c.project;
    final editable = hasSelection && !c.selectedItems.every((e) => e.locked);
    return [
      RibbonTab(
        id: 'file',
        label: 'ملف',
        groups: [
          RibbonGroup(
            label: 'الصور',
            children: [
              RibbonButton(
                key: const Key('rb-import'),
                icon: Icons.add_photo_alternate_outlined,
                label: 'إضافة صور',
                large: true,
                tooltip: 'اختيار صور المستمسكات: تُقص وتُصنّف وتُرتّب تلقائياً',
                onPressed: busy || widget.pickImages == null
                    ? null
                    : c.importImages,
              ),
            ],
          ),
          RibbonGroup(
            label: 'الإخراج',
            children: [
              RibbonButton(
                key: const Key('rb-export'),
                icon: Icons.print_outlined,
                label: 'طباعة وتصدير',
                large: true,
                tooltip: 'معاينة نهائية ثم PDF أو PNG أو JPG أو طباعة (Ctrl + P)',
                onPressed: busy || project.items.isEmpty ? null : _openExport,
              ),
            ],
          ),
          RibbonGroup(
            label: 'المحرر',
            children: [
              RibbonButton(
                key: const Key('rb-shortcuts'),
                icon: Icons.keyboard_outlined,
                label: 'اختصارات',
                large: true,
                onPressed: () => showShortcuts(context, _shortcuts),
              ),
              RibbonButton(
                key: const Key('rb-close'),
                icon: Icons.logout,
                label: 'إغلاق المحرر',
                large: true,
                onPressed: busy ? null : _leave,
              ),
            ],
          ),
        ],
      ),
      RibbonTab(
        id: 'home',
        label: 'الرئيسية',
        groups: [
          RibbonGroup(
            label: 'التحرير',
            children: [
              RibbonButton(
                key: const Key('rb-undo'),
                icon: Icons.undo,
                label: 'تراجع',
                large: true,
                tooltip: 'تراجع (Ctrl + Z)',
                onPressed: c.canUndo ? c.undo : null,
              ),
              RibbonButton(
                key: const Key('rb-redo'),
                icon: Icons.redo,
                label: 'إعادة',
                large: true,
                tooltip: 'إعادة (Ctrl + Y)',
                onPressed: c.canRedo ? c.redo : null,
              ),
              RibbonStack(
                children: [
                  RibbonButton(
                    key: const Key('rb-duplicate'),
                    icon: Icons.copy_all_outlined,
                    label: 'تكرار',
                    tooltip: 'نسخة أخرى من المحدد (Ctrl + D)',
                    onPressed: busy || !hasSelection ? null : c.duplicate,
                  ),
                  RibbonButton(
                    key: const Key('rb-delete'),
                    icon: Icons.delete_outline,
                    label: 'حذف',
                    tooltip: 'حذف المحدد من الورق (Delete)',
                    onPressed: busy || !hasSelection ? null : c.deleteSelected,
                  ),
                  RibbonButton(
                    key: const Key('rb-select-all'),
                    icon: Icons.select_all,
                    label: 'تحديد الكل',
                    tooltip: 'تحديد الكل (Ctrl + A)',
                    onPressed: project.items.isEmpty ? null : c.selectAll,
                  ),
                ],
              ),
            ],
          ),
          RibbonGroup(
            label: 'نوع المستمسك',
            children: [
              for (final kind in _galleryKinds)
                RibbonButton(
                  key: Key('rb-kind-${kind.name}'),
                  icon: _kindIcon(kind),
                  label: kind.label,
                  large: true,
                  selected: item?.documentKind == kind,
                  tooltip: kind.sizeNote(project.catalog),
                  onPressed: busy || !editable ? null : () => c.setKind(kind),
                ),
            ],
          ),
          RibbonGroup(
            label: 'الترتيب',
            children: [
              RibbonButton(
                key: const Key('rb-arrange'),
                icon: Icons.auto_awesome_mosaic_outlined,
                label: 'ترتيب تلقائي',
                large: true,
                tooltip:
                    'ترتيب الآن: البطاقة الوطنية ثم السكن ثم الجواز ثم التموينية، وتُضاف صفحات عند الحاجة',
                onPressed: busy || project.items.isEmpty ? null : c.arrangeNow,
              ),
              RibbonStack(
                children: [
                  RibbonButton(
                    key: const Key('rb-autoflow'),
                    icon: Icons.sync_alt,
                    label: 'ترتيب مستمر',
                    selected: c.autoFlow,
                    tooltip: 'إعادة الترتيب تلقائياً بعد كل تعديل',
                    onPressed: busy ? null : () => c.setAutoFlow(!c.autoFlow),
                  ),
                  RibbonMenuButton<ArrangementStrategy>(
                    key: const Key('rb-strategy'),
                    icon: Icons.view_quilt_outlined,
                    label: project.layout.strategy == ArrangementStrategy.ordered
                        ? 'حسب النوع'
                        : 'مضغوط',
                    tooltip: 'طريقة الترتيب',
                    enabled: !busy,
                    onSelected: c.setStrategy,
                    entries: [
                      RibbonMenuEntry(
                        ArrangementStrategy.ordered,
                        'حسب النوع (صف لكل نوع)',
                        checked:
                            project.layout.strategy ==
                            ArrangementStrategy.ordered,
                      ),
                      RibbonMenuEntry(
                        ArrangementStrategy.compact,
                        'مضغوط (أكبر عدد في الصفحة)',
                        checked:
                            project.layout.strategy ==
                            ArrangementStrategy.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      RibbonTab(
        id: 'insert',
        label: 'إدراج',
        groups: [
          RibbonGroup(
            label: 'صور',
            children: [
              RibbonButton(
                key: const Key('rb-insert-images'),
                icon: Icons.photo_library_outlined,
                label: 'صور مستمسكات',
                large: true,
                onPressed: busy || widget.pickImages == null
                    ? null
                    : c.importImages,
              ),
            ],
          ),
          RibbonGroup(
            label: 'الصفحات',
            children: [
              RibbonButton(
                key: const Key('rb-add-page'),
                icon: Icons.note_add_outlined,
                label: 'صفحة فارغة',
                large: true,
                onPressed: busy || project.pageCount >= 100 ? null : c.addPage,
              ),
              RibbonButton(
                key: const Key('rb-remove-empty-pages'),
                icon: Icons.layers_clear_outlined,
                label: 'حذف الصفحات الفارغة',
                large: true,
                onPressed: busy ? null : c.removeEmptyPages,
              ),
            ],
          ),
          RibbonGroup(
            label: 'نسخ',
            children: [
              RibbonMenuButton<int>(
                key: const Key('rb-copies'),
                icon: Icons.library_add_outlined,
                label: 'نسخ إضافية',
                large: true,
                enabled: !busy && hasSelection,
                onSelected: _copies,
                entries: [
                  for (final n in const [1, 2, 3, 4, 6, 8])
                    RibbonMenuEntry(n, '$n'),
                  const RibbonMenuEntry(0, 'عدد مخصص…'),
                ],
              ),
            ],
          ),
        ],
      ),
      RibbonTab(
        id: 'layout',
        label: 'تخطيط الصفحة',
        groups: [
          RibbonGroup(
            label: 'إعداد الصفحة',
            children: [
              RibbonMenuButton<double>(
                key: const Key('rb-margins'),
                icon: Icons.border_outer,
                label: 'الهوامش',
                large: true,
                enabled: !busy,
                onSelected: (value) => value < 0
                    ? _customMargins()
                    : c.setMargins(Margins.all(value)),
                entries: [
                  for (final preset in const [
                    (10.0, 'عادية · 10 مم'),
                    (5.0, 'ضيقة · 5 مم'),
                    (3.0, 'ضيقة جداً · 3 مم'),
                    (0.0, 'بلا هوامش'),
                  ])
                    RibbonMenuEntry(
                      preset.$1,
                      preset.$2,
                      checked:
                          project.paper.margins.isUniform &&
                          project.paper.margins.top == preset.$1,
                    ),
                  RibbonMenuEntry(
                    -1,
                    'هوامش مخصصة…',
                    checked: !project.paper.margins.isUniform,
                  ),
                ],
              ),
              RibbonMenuButton<PaperOrientation>(
                key: const Key('rb-orientation'),
                icon: project.paper.orientation == PaperOrientation.portrait
                    ? Icons.crop_portrait
                    : Icons.crop_landscape,
                label: 'الاتجاه',
                large: true,
                enabled: !busy,
                onSelected: c.setOrientation,
                entries: [
                  RibbonMenuEntry(
                    PaperOrientation.portrait,
                    'A4 عمودي',
                    icon: Icons.crop_portrait,
                    checked:
                        project.paper.orientation == PaperOrientation.portrait,
                  ),
                  RibbonMenuEntry(
                    PaperOrientation.landscape,
                    'A4 أفقي',
                    icon: Icons.crop_landscape,
                    checked:
                        project.paper.orientation == PaperOrientation.landscape,
                  ),
                ],
              ),
            ],
          ),
          RibbonGroup(
            label: 'التباعد بين المستمسكات',
            children: [
              RibbonStack(
                children: [
                  RibbonNumberField(
                    fieldKey: const Key('rb-gap-h'),
                    label: 'أفقي',
                    value: project.layout.horizontalGap,
                    max: 50,
                    step: .5,
                    enabled: !busy,
                    onChanged: (v) => c.setGaps(horizontal: v),
                  ),
                  RibbonNumberField(
                    fieldKey: const Key('rb-gap-v'),
                    label: 'عمودي',
                    value: project.layout.verticalGap,
                    max: 50,
                    step: .5,
                    enabled: !busy,
                    onChanged: (v) => c.setGaps(vertical: v),
                  ),
                ],
              ),
            ],
          ),
          RibbonGroup(
            label: 'خيارات الترتيب',
            children: [
              RibbonStack(
                children: [
                  RibbonButton(
                    key: const Key('rb-rotation'),
                    icon: Icons.screen_rotation_alt_outlined,
                    label: 'السماح بالتدوير',
                    selected: project.layout.allowRotation,
                    tooltip: 'تدوير المستمسك 90° إذا لم يتسع بغير ذلك',
                    onPressed: busy
                        ? null
                        : () => c.setAllowRotation(!project.layout.allowRotation),
                  ),
                  RibbonButton(
                    key: const Key('rb-largest-first'),
                    icon: Icons.sort,
                    label: 'الأكبر أولاً',
                    selected: project.layout.order == LayoutOrder.area,
                    tooltip: 'داخل النوع الواحد: الأكبر مساحة أولاً',
                    onPressed: busy
                        ? null
                        : () => c.setOrder(
                            project.layout.order == LayoutOrder.area
                                ? LayoutOrder.input
                                : LayoutOrder.area,
                          ),
                  ),
                  RibbonButton(
                    key: const Key('rb-overlap'),
                    icon: Icons.layers_outlined,
                    label: 'السماح بالتراكب',
                    selected: c.allowOverlap,
                    tooltip: 'السماح بتراكب العناصر عند الترتيب اليدوي',
                    onPressed: () => c.setAllowOverlap(!c.allowOverlap),
                  ),
                ],
              ),
            ],
          ),
          RibbonGroup(
            label: 'المقاسات',
            children: [
              RibbonButton(
                key: const Key('rb-catalog'),
                icon: Icons.straighten,
                label: 'مقاسات المستمسكات',
                large: true,
                tooltip: 'عرض المقاسات الرسمية وتعديل مقاس بطاقة السكن والتموينية',
                onPressed: busy ? null : _editCatalog,
              ),
            ],
          ),
        ],
      ),
      if (item != null)
        RibbonTab(
          id: 'document',
          label: 'المستمسك',
          contextual: true,
          groups: [
            RibbonGroup(
              label: 'النوع',
              children: [
                RibbonMenuButton<DocumentKind>(
                  key: const Key('rb-kind-menu'),
                  icon: _kindIcon(item.documentKind),
                  label: item.documentKind.label,
                  large: true,
                  enabled: !busy && editable,
                  onSelected: c.setKind,
                  entries: [
                    for (final kind in _menuKinds)
                      RibbonMenuEntry(
                        kind,
                        kind.label,
                        icon: _kindIcon(kind),
                        checked: kind == item.documentKind,
                      ),
                  ],
                ),
              ],
            ),
            RibbonGroup(
              label: item.documentKind.hasOfficialSize
                  ? 'الحجم · مقاس رسمي'
                  : 'الحجم',
              children: [
                RibbonStack(
                  children: [
                    RibbonNumberField(
                      key: ValueKey('w-${item.id}'),
                      fieldKey: const Key('rb-width'),
                      label: 'العرض',
                      value: item.width,
                      min: minDocumentEdgeMm,
                      max: maxDocumentEdgeMm,
                      decimals: 2,
                      enabled: !busy && !item.locked,
                      onChanged: (v) => c.resizeActive(width: v),
                    ),
                    RibbonNumberField(
                      key: ValueKey('h-${item.id}'),
                      fieldKey: const Key('rb-height'),
                      label: 'الارتفاع',
                      value: item.height,
                      min: minDocumentEdgeMm,
                      max: maxDocumentEdgeMm,
                      decimals: 2,
                      enabled: !busy && !item.locked,
                      onChanged: (v) => c.resizeActive(height: v),
                    ),
                  ],
                ),
                RibbonStack(
                  children: [
                    RibbonButton(
                      key: const Key('rb-aspect-lock'),
                      icon: Icons.link,
                      label: 'تثبيت النسبة',
                      selected: item.keepAspectRatio,
                      onPressed: busy || item.locked ? null : c.toggleAspectLock,
                    ),
                    RibbonButton(
                      key: const Key('rb-reset-size'),
                      icon: Icons.settings_backup_restore,
                      label: 'المقاس القياسي',
                      tooltip: item.documentKind.sizeNote(project.catalog),
                      onPressed:
                          busy ||
                              item.locked ||
                              project.catalog.natural(item.documentKind) == null
                          ? null
                          : c.resetSize,
                    ),
                  ],
                ),
              ],
            ),
            RibbonGroup(
              label: 'ترتيب',
              children: [
                RibbonButton(
                  key: const Key('rb-rotate-sheet'),
                  icon: Icons.rotate_90_degrees_cw_outlined,
                  label: 'تدوير 90°',
                  large: true,
                  tooltip: 'تدوير المستمسك على الورقة (Ctrl + R)',
                  onPressed: busy || !editable ? null : c.rotateOnSheet,
                ),
                RibbonStack(
                  children: [
                    RibbonButton(
                      key: const Key('rb-lock'),
                      icon: item.locked ? Icons.lock : Icons.lock_open,
                      label: 'تثبيت الموضع',
                      selected: item.locked,
                      tooltip: 'المثبت لا يتحرك عند الترتيب التلقائي',
                      onPressed: busy ? null : c.toggleLock,
                    ),
                    RibbonButton(
                      key: const Key('rb-forward'),
                      icon: Icons.flip_to_front,
                      label: 'إحضار للأمام',
                      onPressed: busy || item.locked ? null : c.bringForward,
                    ),
                    RibbonButton(
                      key: const Key('rb-backward'),
                      icon: Icons.flip_to_back,
                      label: 'إرسال للخلف',
                      onPressed: busy || item.locked ? null : c.sendBackward,
                    ),
                  ],
                ),
              ],
            ),
            RibbonGroup(
              label: 'محاذاة',
              children: [
                RibbonMenuButton<PageAlignment>(
                  key: const Key('rb-align'),
                  icon: Icons.align_horizontal_center,
                  label: 'محاذاة',
                  large: true,
                  enabled: !busy && editable && item.pageIndex != null,
                  onSelected: c.align,
                  entries: const [
                    RibbonMenuEntry(
                      PageAlignment.right,
                      'محاذاة لليمين',
                      icon: Icons.align_horizontal_right,
                    ),
                    RibbonMenuEntry(
                      PageAlignment.centerX,
                      'توسيط أفقي',
                      icon: Icons.align_horizontal_center,
                    ),
                    RibbonMenuEntry(
                      PageAlignment.left,
                      'محاذاة لليسار',
                      icon: Icons.align_horizontal_left,
                    ),
                    RibbonMenuEntry(
                      PageAlignment.top,
                      'محاذاة للأعلى',
                      icon: Icons.align_vertical_top,
                    ),
                    RibbonMenuEntry(
                      PageAlignment.centerY,
                      'توسيط عمودي',
                      icon: Icons.align_vertical_center,
                    ),
                    RibbonMenuEntry(
                      PageAlignment.bottom,
                      'محاذاة للأسفل',
                      icon: Icons.align_vertical_bottom,
                    ),
                  ],
                ),
                RibbonStack(
                  children: [
                    RibbonButton(
                      key: const Key('rb-distribute-h'),
                      icon: Icons.horizontal_distribute,
                      label: 'توزيع أفقي',
                      tooltip: 'يتطلب ثلاثة عناصر محددة من صفحة واحدة',
                      onPressed: busy || c.selected.length < 3
                          ? null
                          : () => c.distribute(horizontal: true),
                    ),
                    RibbonButton(
                      key: const Key('rb-distribute-v'),
                      icon: Icons.vertical_distribute,
                      label: 'توزيع عمودي',
                      tooltip: 'يتطلب ثلاثة عناصر محددة من صفحة واحدة',
                      onPressed: busy || c.selected.length < 3
                          ? null
                          : () => c.distribute(horizontal: false),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      if (item != null && asset != null)
        RibbonTab(
          id: 'picture',
          label: 'الصورة',
          contextual: true,
          groups: [
            RibbonGroup(
              label: 'القص',
              children: [
                RibbonButton(
                  key: const Key('rb-crop'),
                  icon: Icons.crop,
                  label: 'القص والحدود',
                  large: true,
                  tooltip: 'ضبط زوايا المستمسك وتصحيح المنظور',
                  onPressed: busy || widget.service.imageEditor == null
                      ? null
                      : _editCrop,
                ),
                RibbonButton(
                  key: const Key('rb-rotate-image'),
                  icon: Icons.rotate_right,
                  label: 'تدوير الصورة',
                  large: true,
                  tooltip: 'تدوير محتوى الصورة 90° وتبديل العرض والارتفاع',
                  onPressed: busy || widget.service.imageEditor == null
                      ? null
                      : c.rotateImage,
                ),
              ],
            ),
            _adjustGroup(asset, busy),
            RibbonGroup(
              label: 'تحسين',
              children: [
                RibbonButton(
                  key: const Key('rb-auto-adjust'),
                  icon: Icons.auto_fix_high_outlined,
                  label: 'تحسين تلقائي',
                  large: true,
                  onPressed: busy || widget.service.imageEditor == null
                      ? null
                      : c.autoAdjust,
                ),
                RibbonButton(
                  key: const Key('rb-reset-adjust'),
                  icon: Icons.restart_alt,
                  label: 'إعادة ضبط',
                  large: true,
                  tooltip: 'إزالة تعديلات الإضاءة والتباين والتشبع والحدة',
                  onPressed:
                      busy ||
                          widget.service.imageEditor == null ||
                          !_hasCorrections(c.adjustmentsFor(asset))
                      ? null
                      : c.resetAdjustments,
                ),
              ],
            ),
          ],
        ),
      RibbonTab(
        id: 'view',
        label: 'عرض',
        groups: [
          RibbonGroup(
            label: 'التكبير',
            children: [
              RibbonButton(
                key: const Key('rb-zoom-100'),
                icon: Icons.crop_free,
                label: '100%',
                large: true,
                tooltip: 'الحجم الحقيقي تقريباً',
                selected:
                    c.zoomMode == ZoomMode.custom && (c.zoom - 1).abs() < 1e-6,
                onPressed: () => c.setZoom(1),
              ),
              RibbonButton(
                key: const Key('rb-zoom-width'),
                icon: Icons.width_normal_outlined,
                label: 'عرض الصفحة',
                large: true,
                selected: c.zoomMode == ZoomMode.pageWidth,
                onPressed: () => c.setZoomMode(ZoomMode.pageWidth),
              ),
              RibbonButton(
                key: const Key('rb-zoom-page'),
                icon: Icons.fit_screen_outlined,
                label: 'صفحة كاملة',
                large: true,
                selected: c.zoomMode == ZoomMode.wholePage,
                onPressed: () => c.setZoomMode(ZoomMode.wholePage),
              ),
              RibbonStack(
                children: [
                  RibbonButton(
                    key: const Key('rb-zoom-in'),
                    icon: Icons.zoom_in,
                    label: 'تكبير',
                    onPressed: c.zoom < maxZoom ? c.zoomIn : null,
                  ),
                  RibbonButton(
                    key: const Key('rb-zoom-out'),
                    icon: Icons.zoom_out,
                    label: 'تصغير',
                    onPressed: c.zoom > minZoom ? c.zoomOut : null,
                  ),
                ],
              ),
            ],
          ),
          RibbonGroup(
            label: 'إظهار',
            children: [
              RibbonButton(
                key: const Key('rb-guides'),
                icon: Icons.border_style,
                label: 'حدود الهوامش',
                large: true,
                selected: c.showGuides,
                onPressed: () => c.setShowGuides(!c.showGuides),
              ),
            ],
          ),
        ],
      ),
    ];
  }

  bool _hasCorrections(ImageAdjustments a) =>
      a.hasColorChange || a.sharpness != 0;

  Widget _adjustGroup(ImageAsset asset, bool busy) {
    final a = _c.adjustmentsFor(asset);
    final enabled = !busy && widget.service.imageEditor != null;
    String percent(double v) => '${(v * 100).round()}';
    return RibbonGroup(
      label: 'ضبط الصورة (مباشر)',
      children: [
        RibbonStack(
          children: [
            RibbonSlider(
              sliderKey: const Key('rb-brightness'),
              label: 'الإضاءة',
              value: a.brightness,
              min: -.5,
              max: .5,
              display: percent,
              onChanged: enabled
                  ? (v) => _c.liveAdjust(a.copyWith(brightness: v))
                  : null,
            ),
            RibbonSlider(
              sliderKey: const Key('rb-contrast'),
              label: 'التباين',
              value: a.contrast,
              min: .25,
              max: 3,
              display: percent,
              onChanged: enabled
                  ? (v) => _c.liveAdjust(a.copyWith(contrast: v))
                  : null,
            ),
          ],
        ),
        RibbonStack(
          children: [
            RibbonSlider(
              sliderKey: const Key('rb-saturation'),
              label: 'التشبع',
              value: a.saturation,
              min: 0,
              max: 2,
              display: percent,
              onChanged: enabled
                  ? (v) => _c.liveAdjust(a.copyWith(saturation: v))
                  : null,
            ),
            RibbonSlider(
              sliderKey: const Key('rb-sharpness'),
              label: 'الحدة',
              value: a.sharpness,
              min: 0,
              max: 1,
              display: percent,
              onChanged: enabled
                  ? (v) => _c.liveAdjust(a.copyWith(sharpness: v))
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final tabs = _tabs();
    if (!tabs.any((t) => t.id == _tab)) _tab = 'home';
    return ScreenShortcuts(
      shortcuts: _shortcuts,
      child: PopScope<Project>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !c.busy) unawaited(_leave());
        },
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 44,
            titleSpacing: 0,
            leading: IconButton(
              tooltip: 'رجوع للمشروع',
              onPressed: c.busy ? null : _leave,
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text(
              '${c.project.name} · محرر A4',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            actions: [
              IconButton(
                key: const Key('qa-undo'),
                tooltip: 'تراجع',
                onPressed: c.canUndo ? c.undo : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                key: const Key('qa-redo'),
                tooltip: 'إعادة',
                onPressed: c.canRedo ? c.redo : null,
                icon: const Icon(Icons.redo),
              ),
            ],
          ),
          body: Column(
            children: [
              Ribbon(
                tabs: tabs,
                selectedTab: _tab,
                onTabSelected: (id) => setState(() => _tab = id),
              ),
              SizedBox(
                height: 3,
                child: c.busy ? const LinearProgressIndicator() : null,
              ),
              if (c.error != null)
                _Banner(
                  key: const Key('editor-error'),
                  text: c.error!,
                  error: true,
                  onClose: () => setState(() => c.error = null),
                ),
              if (widget.intakeSummary != null && _intakeVisible)
                _Banner(
                  key: const Key('intake-summary'),
                  text: [
                    widget.intakeSummary!,
                    ...widget.intakeWarnings.take(3),
                    if (widget.intakeWarnings.length > 3)
                      'وتوجد ${widget.intakeWarnings.length - 3} تنبيهات أخرى.',
                  ].join('\n'),
                  onClose: () => setState(() => _intakeVisible = false),
                ),
              Expanded(child: SheetView(controller: c)),
              OffSheetTray(controller: c),
              EditorStatusBar(controller: c),
            ],
          ),
        ),
      ),
    );
  }
}

const _galleryKinds = [
  DocumentKind.unifiedNationalId,
  DocumentKind.residenceCard,
  DocumentKind.passport,
  DocumentKind.rationCard,
];

const _menuKinds = [
  DocumentKind.unifiedNationalId,
  DocumentKind.residenceCard,
  DocumentKind.passport,
  DocumentKind.rationCard,
  DocumentKind.other,
  DocumentKind.unknown,
];

IconData _kindIcon(DocumentKind kind) => switch (kind) {
  DocumentKind.unifiedNationalId => Icons.badge_outlined,
  DocumentKind.residenceCard => Icons.home_work_outlined,
  DocumentKind.passport => Icons.menu_book_outlined,
  DocumentKind.rationCard => Icons.receipt_long_outlined,
  DocumentKind.other => Icons.description_outlined,
  DocumentKind.unknown => Icons.help_outline,
};

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.onClose,
    this.error = false,
    super.key,
  });

  final String text;
  final VoidCallback onClose;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: error ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: error ? scheme.onErrorContainer : scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: error
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: 'إغلاق',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edits the printed sizes per category. Official sizes are shown, not
/// editable; residence and ration card defaults can be changed.
class CatalogDialog extends StatefulWidget {
  const CatalogDialog({required this.catalog, super.key});

  final DocumentSizeCatalog catalog;

  @override
  State<CatalogDialog> createState() => _CatalogDialogState();
}

class _CatalogDialogState extends State<CatalogDialog> {
  late final _fields = {
    'residence-w': TextEditingController(
      text: _fmt(widget.catalog.residenceCard.width),
    ),
    'residence-h': TextEditingController(
      text: _fmt(widget.catalog.residenceCard.height),
    ),
    'ration-w': TextEditingController(
      text: _fmt(widget.catalog.rationCard.width),
    ),
    'ration-h': TextEditingController(
      text: _fmt(widget.catalog.rationCard.height),
    ),
  };
  String? _error;

  static String _fmt(double v) => v.toStringAsFixed(2);

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _restoreDefaults() {
    _fields['residence-w']!.text = _fmt(
      DocumentSizeCatalog.defaultResidenceCard.width,
    );
    _fields['residence-h']!.text = _fmt(
      DocumentSizeCatalog.defaultResidenceCard.height,
    );
    _fields['ration-w']!.text = _fmt(
      DocumentSizeCatalog.defaultRationCard.width,
    );
    _fields['ration-h']!.text = _fmt(
      DocumentSizeCatalog.defaultRationCard.height,
    );
    setState(() => _error = null);
  }

  void _save() {
    double read(String key) {
      final value = parseLocalizedNumber(_fields[key]!.text);
      if (value == null) {
        throw const FormatException('أدخل أرقاماً صالحة.');
      }
      return value;
    }

    try {
      final catalog = widget.catalog.copyWith(
        residenceCard: PhysicalSizeMm(read('residence-w'), read('residence-h')),
        rationCard: PhysicalSizeMm(read('ration-w'), read('ration-h')),
      );
      Navigator.pop(context, catalog);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = userError(e));
    }
  }

  Widget _row(String label, String prefix) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        SizedBox(
          width: 90,
          child: TextField(
            key: Key('catalog-$prefix-w'),
            controller: _fields['$prefix-w'],
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'العرض مم',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 90,
          child: TextField(
            key: Key('catalog-$prefix-h'),
            controller: _fields['$prefix-h'],
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'الارتفاع مم',
              isDense: true,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('مقاسات المستمسكات'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${DocumentKind.unifiedNationalId.label}: ${DocumentSizeCatalog.unifiedNationalId} — مقاس رسمي (ISO/IEC 7810 ID-1)',
            ),
            const SizedBox(height: 4),
            Text(
              '${DocumentKind.passport.label}: ${DocumentSizeCatalog.passport} — مقاس رسمي لصفحة البيانات (ICAO 9303 TD3)',
            ),
            const Divider(height: 24),
            const Text(
              'لا يوجد مقاس رسمي منشور للمستمسكين التاليين؛ القيم افتراضية قابلة للتعديل وتُطبّق فوراً على كل المستمسكات من نوعها في المشروع، وتُعتمد للمشاريع الجديدة.',
            ),
            _row(DocumentKind.residenceCard.label, 'residence'),
            _row(DocumentKind.rationCard.label, 'ration'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('catalog-defaults'),
        onPressed: _restoreDefaults,
        child: const Text('استعادة الافتراضي'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        key: const Key('catalog-save'),
        onPressed: _save,
        child: const Text('حفظ وتطبيق'),
      ),
    ],
  );
}

/// Small numeric form used by the ribbon's "custom…" entries. Accepts Latin
/// and Arabic-Indic digits.
Future<Map<String, double>?> editMeasurements(
  BuildContext context,
  String title,
  Map<String, double> values, {
  int decimals = 2,
}) => showDialog<Map<String, double>>(
  context: context,
  builder: (_) =>
      _MeasurementsDialog(title: title, values: values, decimals: decimals),
);

class _MeasurementsDialog extends StatefulWidget {
  const _MeasurementsDialog({
    required this.title,
    required this.values,
    required this.decimals,
  });

  final String title;
  final Map<String, double> values;
  final int decimals;

  @override
  State<_MeasurementsDialog> createState() => _MeasurementsDialogState();
}

class _MeasurementsDialogState extends State<_MeasurementsDialog> {
  late final _fields = {
    for (final e in widget.values.entries)
      e.key: TextEditingController(
        text: e.value.toStringAsFixed(widget.decimals),
      ),
  };
  String? _error;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final values = <String, double>{};
    for (final e in _fields.entries) {
      final value = parseLocalizedNumber(e.value.text);
      if (value == null) {
        setState(() => _error = 'أدخل أرقاماً صالحة.');
        return;
      }
      values[e.key] = value;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _fields.entries)
              TextField(
                key: Key('measure-${e.key}'),
                controller: e.value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: e.key),
                onSubmitted: (_) => _save(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        key: const Key('measure-save'),
        onPressed: _save,
        child: const Text('حفظ'),
      ),
    ],
  );
}
