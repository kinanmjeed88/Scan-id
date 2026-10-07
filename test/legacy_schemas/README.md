# Frozen project writers of earlier releases

Each directory holds the domain files that serialized a project in one earlier
release, copied **byte for byte** from the commit in the directory name
(`git show <commit>:lib/domain/<file>.dart`). They exist only so that
`test/persistence/legacy_schema_test.dart` can write real old-format projects
with the code that originally wrote them, then open them with the current app.

| Directory | Stored format |
|---|---|
| `v1_1c68dbc` | schema 1 |
| `v2_cd58739` | schema 2 (image adjustments) |
| `v3a_478e098` | schema 3 (pages) |
| `v3b_90de23c` | schema 3 + `captureId` (same number) |
| `v3c_64d146e` | schema 3 + document category, confidence, size confirmation (same number) |

These are every distinct `toJson` output that shipped on `searchidf` before
schema 4. Do not edit, reformat or "fix" these files. When a future release
changes the stored format, add a new directory for the release being replaced.
