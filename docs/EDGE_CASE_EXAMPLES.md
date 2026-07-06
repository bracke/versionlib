# Release edge-case examples

This page collects short, copyable examples for release-hardened behavior that is easy to misunderstand. The examples describe the supported contract; they are not a replacement for the regression tests.

## Restore with submodule gitlinks

A submodule entry is a Git tree entry with mode `160000`. Version treats that path as a repository boundary during parent-directory restore.

```sh
version restore vendor
```

Expected behavior:

```text
vendor/app.txt                  restored when tracked by the selected source
vendor/lib                      preserved as a gitlink/submodule boundary
vendor/lib/local-dirty-file.txt preserved; parent restore does not recurse into it
```

If the selected source no longer contains the gitlink, a working-tree restore of the parent directory preserves the existing submodule worktree and gitlink index entry. A staged restore may remove a source-missing gitlink from the index, but it must not delete the submodule working tree.

## Archive unsafe path rejection

Archive export validates every committed tree entry before writing the final archive path. Unsafe names are rejected before the final output is replaced.

Rejected examples include:

```text
../escape
.git/config
.git/hooks/post-checkout
a//b
C:/escape
..\escape
```

A failed export writes only to a same-directory temporary archive path and removes that temporary path on failure. A preexisting archive at the requested output path remains unchanged.

```sh
version archive --format zip HEAD release.zip
```

If the tree contains an unsafe path, `release.zip` remains the old file if it already existed, or is absent if it did not.

## SHA-256 object-format repositories

Version supports ordinary SHA-1 Git repositories. SHA-256 object-format repositories are intentionally unsupported in this release and must fail before mutation.

```sh
git init --object-format=sha256 sha256-repo
cd sha256-repo
version status
```

Expected behavior:

```text
error: unsupported repository format: SHA-256 object-format repositories are not supported
```

The same pre-mutation rejection applies to user-facing commands such as `stage`, `restore`, `save`, and `fetch`. The index, refs, reflogs, working-tree files, and remote-tracking refs must remain byte-for-byte unchanged after rejection.

## Hook post-commit no-rollback behavior

`post-commit` runs after the commit object, branch ref, and reflog have been written. A failing `post-commit` reports failure but does not roll back the completed commit.

```sh
mkdir -p .git/hooks
cat > .git/hooks/post-commit <<'HOOK'
#!/bin/sh
exit 7
HOOK
chmod +x .git/hooks/post-commit

version stage file.txt
version save "record file"
```

Expected behavior:

```text
error: hook failed: post-commit
```

The new commit remains reachable from `HEAD`. `post-commit` is not run for no-op saves or when commit creation fails before the ref update.

## Transport failure no-mutation guarantee

Fetch and push failures must not silently commit local state changes. For failed fetches, existing remote-tracking refs and shallow metadata are preserved.

```sh
old_ref=$(cat .git/refs/remotes/origin/main)
old_shallow=$(cat .git/shallow 2>/dev/null || true)

version fetch origin main || true

test "$old_ref" = "$(cat .git/refs/remotes/origin/main)"
```

Failure modes covered by the release tests include malformed pkt-lines, truncated packs, upload-pack fatal sidebands, bad pack checksums, missing delta bases, HTTP discovery failure, shallow capability failure, and SSH backend failures. Temporary fetch or push pack/index files must be removed after failure.

## Platform CI evidence workflow

Release certification requires both POSIX and Windows evidence. The CI gate scripts emit platform evidence when `VERSION_PLATFORM_CI_EVIDENCE_DIR` is set.

```sh
mkdir -p .release/platform-ci-evidence
VERSION_PLATFORM_CI_EVIDENCE_DIR=.release/platform-ci-evidence \
  tools/check_platform_ci_matrix.adb
```

On Windows, run the PowerShell gate with the same evidence directory setting:

```powershell
$env:VERSION_PLATFORM_CI_EVIDENCE_DIR = ".release/platform-ci-evidence"
tools/check_platform_ci_matrix.adb
```

After both platforms finish, validate and summarize the release evidence:

```sh
tools/bin/check_platform_ci_evidence .release/platform-ci-evidence
tools/bin/summarize_release_evidence .release/platform-ci-evidence
```

The evidence check requires matching source-tree identity, real platform filesystem mode, successful build, successful AUnit run, successful release consistency check, and no skipped/not-run/failed markers.
