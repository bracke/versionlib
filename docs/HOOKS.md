# Client-side hooks

Supported hooks:

```text
pre-commit
commit-msg
pre-merge-commit
post-commit
post-checkout
pre-push
post-merge
```

Missing hooks are successful no-ops. Hook paths are allow-listed and invoked through direct process arguments, not shell interpolation. POSIX hooks must be ordinary executable files; non-executable or symlinked hook files are ignored as no-ops.

For `version save`, the lifecycle is `pre-commit`, message-file preparation, `commit-msg`, tree/commit object creation, ref/reflog update, optional `post-commit`, and success reporting. `commit-msg` receives the message-file path and may edit it. Use `version save --no-verify MESSAGE` or amend variants to bypass blocking save hooks. `post-commit` runs only after the commit object, ref update, and reflog update have completed; a failing `post-commit` is reported but does not roll back the completed commit.

`pre-merge-commit` runs before clean automatic merge commits when hooks are enabled, and `version merge --no-verify` bypasses it. `post-checkout` runs after supported branch, detached, path checkout, and linked-worktree materialization flows. `pre-push` runs before branch or tag push mutation/upload. Use `version push --no-verify ...` to bypass blocking push hooks.

Hook execution sets practical Git-like environment variables such as `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, and `VERSION=1`, runs with the repository root as current directory, and restores process state afterward. Server-side hooks, full Git environment parity beyond the documented variables, timeout UX, and every Git hook name are outside this phase.
