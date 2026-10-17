import 'dart:async';

import 'package:flutter/material.dart';

import '../application/cancellation.dart';
import '../application/ota_update.dart';
import '../application/project_service.dart';
import 'shared.dart';

/// The one offer the app makes when a newer release is published.
///
/// Two situations find an update — the check the app runs when it opens, and
/// the check a person starts in settings — and both must say the same thing and
/// ask the same question. What differs is only where progress is shown, so the
/// caller receives [onDownload] and keeps owning that: the settings card draws
/// it inline, the startup check opens [_UpdateDownloadDialog] because it has no
/// card behind it.
///
/// The dialog itself downloads nothing and installs nothing. It closes on an
/// answer, and only «نعم» reaches [onDownload]; «لاحقاً» is a complete answer
/// that leaves every file as it was.
Future<void> showUpdateOffer(
  BuildContext context, {
  required UpdateInfo update,
  required String currentVersion,
  required bool canInstall,
  required String downloadLabel,
  required Future<void> Function() onDownload,
}) async {
  final notes = update.size == null
      ? 'تُطابق الحزمة بصمتها المنشورة، ويُطابق توقيعها توقيعُ التطبيق المثبَّت '
            'على جهازك.'
      : 'حجم التحديث ${(update.size! / (1024 * 1024)).toStringAsFixed(1)} '
            'MiB. تُطابق الحزمة بصمتها المنشورة، ويُطابق توقيعها توقيعُ '
            'التطبيق المثبَّت على جهازك.';
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('يتوفر إصدار أحدث'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الإصدار الحالي: $currentVersion'),
          Text('الإصدار الجديد: ${update.newVersion}'),
          const SizedBox(height: 8),
          Text(notes),
          const SizedBox(height: 8),
          Text(
            canInstall
                ? 'بعدها يفتح النظام شاشة التثبيت لتؤكّدها أنت.'
                : 'يُحفظ الملف مُتحقَّقاً منه في مساحة التطبيق، ولا يُشغَّل '
                      'شيء تلقائياً.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('لاحقاً'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(downloadLabel),
        ),
      ],
    ),
  );
  if (go == true && context.mounted) {
    await onDownload();
  }
}

/// Checks the release feed once, when the app opens, and offers a newer
/// published version if there is one.
///
/// Quiet by design. The person did not ask for this check, so a failure — no
/// route, a captive portal, a feed that is down — is not reported, and an
/// answer of «nothing newer» is not either. Only a published release speaks,
/// and only to offer itself: downloading starts on a yes, and installing still
/// ends at the system installer's own confirmation. Nothing about the person,
/// their projects or their photos is sent; the request is the fixed release
/// path the settings card already asks for.
///
/// A check that answers after the person has opened a project or settings is
/// dropped instead of covering their work with a dialog: the card in settings
/// can still check on demand, and the offer waits for the next launch.
class StartupUpdateCheck extends StatefulWidget {
  const StartupUpdateCheck({
    required this.service,
    required this.child,
    super.key,
  });

  /// `null` turns the check off. A host with no release feed — a widget test,
  /// for instance — must not be handed a socket it never expected.
  final UpdateService? service;

  final Widget child;

  @override
  State<StartupUpdateCheck> createState() => _StartupUpdateCheckState();
}

class _StartupUpdateCheckState extends State<StartupUpdateCheck> {
  @override
  void initState() {
    super.initState();
    if (widget.service != null) {
      // After the first frame: the offer is a dialog, and a dialog needs the
      // navigator this widget is installed under. The project list also gets to
      // appear first; a check that may spend 25 seconds timing out must never
      // hold up the screen it exists to improve.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_ask());
      });
    }
  }

  Future<void> _ask() async {
    final service = widget.service;
    if (service == null || !mounted) return;
    UpdateInfo? found;
    try {
      found = await service.checkForUpdate();
    } on Object {
      // A courtesy at startup, not a task the person asked for: no failure is
      // worth a warning before they have done anything, and the settings card
      // reports one when they ask for the check themselves.
      return;
    }
    final update = found;
    if (!mounted || update == null) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final canInstall = service.installer != null;
    await showUpdateOffer(
      context,
      update: update,
      currentVersion: service.currentVersion,
      canInstall: canInstall,
      downloadLabel: canInstall ? 'تنزيل وتثبيت' : 'تنزيل وتحقّق',
      onDownload: () => _download(service, update),
    );
  }

  Future<void> _download(UpdateService service, UpdateInfo update) async {
    final message = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDownloadDialog(service: service, update: update),
    );
    if (message != null && mounted) {
      showMessage(context, message);
    }
  }

  /// The check is invisible until it has something to ask; the screen below it
  /// is the app.
  @override
  Widget build(BuildContext context) => widget.child;
}

/// Downloads one update while the person watches, and ends in a sentence.
///
/// The startup offer has no card behind it to show progress on, so this dialog
/// carries the read itself. It owns that read: closing it cancels the download,
/// exactly as leaving the settings screen does, so no socket keeps writing a
/// package nobody is waiting for. A finished download is verified by the
/// service before an installer is offered anything, and a package the platform
/// refuses is reported as refused — never as completed.
class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.service, required this.update});

  final UpdateService service;
  final UpdateInfo update;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  final CancellationToken _cancellation = CancellationToken();
  double _progress = 0;
  bool _running = true;

  /// True once the package is complete and verified and the installer has been
  /// offered it. The read can no longer be cancelled at that point, so the
  /// dialog stops offering a button that would cancel nothing.
  bool _installing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _cancellation.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final DownloadResult result;
    try {
      result = await widget.service.downloadUpdate(
        widget.update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? received / total : 0);
        },
        onCancel: () {},
        cancellation: _cancellation,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _running = false;
          _message = error is UpdateFailure
              ? describeUpdateFailure(error)
              : userError(error);
        });
      }
      return;
    }
    if (!mounted) return;
    if (!result.isSuccess) {
      setState(() {
        _running = false;
        _message = result.error ?? 'تعذر تنزيل التحديث؛ حاول لاحقاً.';
      });
      return;
    }
    setState(() {
      _progress = 1;
      _installing = true;
    });
    final InstallResult install;
    try {
      install = await widget.service.installUpdate(
        widget.update,
        result.filePath!,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _message = error is UpdateFailure
            ? describeUpdateFailure(error)
            : userError(error);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _message = install.message ?? install.error ?? 'اكتمل التحديث.';
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // The dialog is the only place this download can be watched or stopped.
    // Back may close it once the read has ended — answered, refused or handed
    // to the installer — but never silently while a package is still arriving;
    // the cancel button is the way out of that state.
    canPop: !_running || _installing,
    child: AlertDialog(
      title: Text(_running ? 'جاري تنزيل التحديث' : 'تحديث التطبيق'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_running) ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 12),
            Text(
              _installing
                  ? 'يُفتح مثبت النظام…'
                  : 'الإصدار ${widget.update.newVersion}',
            ),
          ] else
            Text(_message ?? 'اكتمل التحديث.'),
        ],
      ),
      actions: [
        if (_running && !_installing)
          TextButton.icon(
            onPressed: () => _cancellation.cancel(),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('إلغاء التنزيل'),
          )
        else if (!_running)
          FilledButton(
            onPressed: () => Navigator.pop(context, _message),
            child: const Text('تم'),
          ),
      ],
    ),
  );
}
