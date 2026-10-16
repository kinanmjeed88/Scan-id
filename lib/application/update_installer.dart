import 'dart:io';

import 'package:flutter/services.dart';

/// Printed when the platform cannot present an installer at all.
const String installUnavailableMessage =
    'لم يتمكن النظام من فتح مثبت التطبيقات. أعد المحاولة لاحقاً.';

/// What the platform answered when the app handed it a verified package.
class InstallOutcome {
  const InstallOutcome({required this.started, this.message});

  /// True only when the system installer accepted the package and is showing
  /// its own confirmation to the user. The app never installs anything itself.
  final bool started;

  /// The sentence the user must read next. Never a filesystem path and never
  /// the name of the feed the package came from.
  final String? message;
}

/// Asks the operating system to install a package the update service has
/// already verified.
///
/// Integrity is settled before an installer is reached: the file's extension,
/// declared size and SHA-256 digest were checked by `UpdateService`. Who
/// *signed* it cannot be settled there — only the platform can read the
/// certificate of the app already installed — so the platform side performs
/// that comparison and refuses a package it cannot attribute to this app's
/// publisher. Deciding *whether* to install still stays with the system
/// installer, so a successful download can never become a silent write.
abstract interface class UpdateInstaller {
  Future<InstallOutcome> install(String filePath);
}

/// Android: hands the verified package to the system package installer through
/// `iq.scanid/updates` (see the Kotlin file of the same purpose).
///
/// The native side owns three things Dart must not do: reading the app's own
/// update directory through the scoped `UpdateFileProvider`, comparing the
/// package's signer with this app's (`signature` below), and starting an
/// `ACTION_VIEW` install, which Android 8 and above grant only to an app the
/// person has explicitly allowed to install packages. The channel answers with
/// an error code; every code becomes a sentence, never a stack trace.
class AndroidPackageInstaller implements UpdateInstaller {
  const AndroidPackageInstaller({
    MethodChannel channel = const MethodChannel('iq.scanid/updates'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<InstallOutcome> install(String filePath) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': filePath});
      return const InstallOutcome(
        started: true,
        message: 'فُتح مثبت النظام لإكمال التحديث؛ أكّد التثبيت فيه.',
      );
    } on PlatformException catch (error) {
      return InstallOutcome(started: false, message: _words(error.code));
    } on Object {
      return const InstallOutcome(
        started: false,
        message: installUnavailableMessage,
      );
    }
  }

  static String _words(String code) => switch (code) {
    'permission' =>
      'يحتاج التطبيق إلى إذن «تثبيت التطبيقات المجهولة» لإكمال التحديث. اسمح له في '
          'إعدادات النظام التي فُتحت الآن، ثم أعد المحاولة.',
    'signature' =>
      'لم تُفتح شاشة التثبيت: توقيع الحزمة ليس توقيع هذا التطبيق المثبَّت، أو '
          'تعذّر التحقق من هويته.',
    'missing' => 'لم يعد ملف التحديث موجوداً؛ نزّله من جديد.',
    'unavailable' =>
      'لا يوجد مثبت تطبيقات على هذا الجهاز؛ لا يمكن إكمال التحديث هنا.',
    _ => installUnavailableMessage,
  };
}

/// The installer this build can use, or `null` where the platform has no native
/// install path. Android completes an over-the-air update; Windows keeps the
/// verified package and refuses to run anything, until a signed installer is
/// configured for it (see `docs/adr/ADR-005.md`).
UpdateInstaller? platformUpdateInstaller() =>
    Platform.isAndroid ? const AndroidPackageInstaller() : null;
