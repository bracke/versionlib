# CLAUDE.md

Guidance for AI agents working in the `versionlib` crate (Claude Code loads this;
other tools read the sibling `AGENTS.md`, which points here).

> This guide is derived from the crate's structure, its `alire.toml`, and the
> conventions documented in the sibling `version` CLI crate — not from extensive
> direct work in this crate. Verify specifics against the code and against
> `../version/CLAUDE.md` / `../version/docs/` before relying on them.

## What this is

`versionlib` is the library crate that holds the functionality of `version`, a
Git-compatible version-control tool in Ada 2022 (Alire/GNAT). All functionality
packages are `Version.*` (objects, refs, staging, transport, diff, replay ops,
etc.); the sibling `version` crate is the **CLI only** and delegates into
`versionlib`. It reads and writes a real `.git` directory and is validated
against the system `git` command.

Dependencies are pinned to sibling directories: `httpclient` (`../httpclient`),
`zlib` (`../zlib`), `i18n` (`../i18n`), and `ssh_lib` (`../sshlib`); `ssh_lib`
brings `cryptolib` transitively. The CLI/test executables link `-lssl -lcrypto`,
so OpenSSL dev libraries are required.

## Build, test, style

- Toolchain: every active manifest pins GNAT 15 through Alire with
  `gnat_native = "=15.2.1"`. Do not run plain system GNAT, GPRBuild,
  GNATprove, GNATdoc, or related `gnat*` tools from `PATH`; use
  `alr exec -- ...` for compiler, builder, prover, and documentation tools.
- Before building or testing, run `alr exec -- gnatls --version`; it must report
  `GNATLS 15.x`.
- Build: `alr build`.
- Functionality suite (AUnit): `(cd tests && alr build) && ./tests/bin/tests`.
- Style is enforced by GNAT flags, not a formatter: Ada 2022, 3-space indent, max
  120 columns, `-gnatwa` + `-gnatVa`. Keep builds warning-clean.

## Conventions

- **Match real Git.** Compatibility means matching the system `git` command's
  behavior and on-disk `.git` format, not just internal consistency; the tests use
  `git` for end-to-end checks. Prefer git's behavior when the tool would diverge.
- Design is cache-aware for scalability (per-command object/tree/ref/pack-index
  caches) — avoid quadratic lookups and spurious re-reads.
- The authoritative behavior/format docs live in the `version` crate's `docs/`
  (`ARCHITECTURE.md`, `COMMANDS.md`, `COMPATIBILITY.md`, `REPOSITORY_FORMAT.md`) —
  consult them before changing behavior. A **Phase 42 release freeze** governs CLI
  output, exit codes, compatibility, transport, archive, hook, and portability
  behavior; flag before changing any of those.
- Add a one-line `CHANGELOG.md` entry for every behavioral change, matching the
  existing terse "Git parity" phrasing.

## When you change behavior

Run the functionality suite, add/adjust tests, keep the `version` crate's docs and
`CHANGELOG.md` in sync, and verify against real `git` end-to-end.
