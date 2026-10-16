// The single source of truth for what this build is and where it updates from.
//
// `release-management.yml` rewrites the [appVersion] line when it publishes a
// version, and `test/application/app_release_test.dart` refuses a build whose
// version disagrees with `pubspec.yaml` or whose line no longer matches the
// pattern that automation edits. One number, in one place, checked by a test:
// a check that compares itself against a stale constant would either offer an
// update forever or never offer one.
//
// The release coordinates below are transport, not content. No screen renders
// them, so a person using the app never sees a repository, a host name or a
// package filename — only whether an update exists and whether it is safe.

/// The published version of this build, as `major.minor.patch` (SemVer).
const String appVersion = '0.1.0';

/// Account that owns the release feed the update check reads.
const String releaseOwner = 'kinanmjeed88';

/// Repository whose published release the update check reads.
const String releaseRepository = 'Scan-id';
