import 'dart:io';

import 'app_release.dart';
import 'ota_update.dart';
import 'update_installer.dart';

/// Builds the one update service a run uses.
///
/// The startup check and the card in settings must agree about what this build
/// is, where the next release is published and which installer the platform can
/// actually open. Composing the service here — from [appVersion] and the
/// release coordinates beside it — keeps that agreement in one place instead of
/// repeating it at every surface that asks the question.
///
/// The platform is read, not guessed: Android has a system installer to hand a
/// verified package to, Windows does not, and a build that claimed otherwise
/// would promise an install it cannot start.
UpdateService buildPlatformUpdateService({String version = appVersion}) =>
    UpdateService(
      source: GitHubUpdateSource(owner: releaseOwner, repo: releaseRepository),
      currentVersion: version,
      platform: Platform.isWindows
          ? UpdatePlatform.windows
          : UpdatePlatform.android,
      installer: platformUpdateInstaller(),
      temporaryDirectory: updateDownloadDirectory,
    );
