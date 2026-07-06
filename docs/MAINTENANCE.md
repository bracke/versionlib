# Maintenance

Maintenance commands inspect and rewrite repository storage while preserving safety roots from branches, tags, HEAD, stash, reflogs where relevant, shallow boundaries, linked worktrees, replay state, and submodules.

* `version verify` checks object consistency and reports missing or malformed data.
* `version repack` writes reachable objects into Git-compatible pack/index files.
* `version prune [--dry-run|--now]` reports or removes unreachable loose objects subject to safety policy.
* `version gc [--dry-run|--now]` runs the implemented maintenance workflow conservatively.
* `version pack-refs [--prune]` packs loose refs and optionally prunes loose copies where safe.

A conservative maintenance false negative that keeps objects is preferable to deleting reachable or possibly-needed objects. Release checks should include `version verify` and `git fsck --strict` on smoke repositories.
