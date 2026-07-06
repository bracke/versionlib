# versionlib

The library crate behind [`version`](../version) — a Git-compatible version-control
system written in Ada 2022. `versionlib` contains all of the functionality (every
`Version.*` package: object storage, refs, staging, transports, diff, replay
operations, and so on). The `version` crate is a thin CLI executable that depends on
this library and implements each command by calling into it.

Status: `0.1.0-dev`, pre-1.0.

## Layout

* `src/` — the `Version.*` packages (root `version.ads` plus the per-domain children).
* `tests/` — a separate Alire crate with the AUnit functionality suite.

## Dependencies

`versionlib` pins sibling crates: `httpclient` (`../HttpClient`), `zlib` (`../zlib`),
`i18n` (`../i18n`), and `ssh_lib` (`../sshlib`). They must be present locally to build.
TLS transport links `-lssl -lcrypto`, so OpenSSL development libraries are required.

## Toolchain

Every active crate manifest pins GNAT 15 through Alire:

```toml
[[depends-on]]
gnat_native = "=15.2.1"
```

Do not run plain system GNAT, GPRBuild, GNATprove, GNATdoc, or related `gnat*`
tools from `PATH`. Build, test, and inspect the compiler through Alire so the
pinned toolchain is selected:

```sh
alr exec -- gnatls --version
alr build
cd tests && alr exec -- gprbuild -P versionlib_tests.gpr
```

The version command must report `GNATLS 15.x`. The release tools verify the
exact `gnat_native = "=15.2.1"` dependency in the root, tests, and tools
manifests before building through Alire.

## Build and test

```sh
alr build
(cd tests && alr build) && ./tests/bin/tests
```

See [`../version/docs/ARCHITECTURE.md`](../version/docs/ARCHITECTURE.md) for the package
ownership map and [`../version/docs/TESTING.md`](../version/docs/TESTING.md) for the full
verification path across both crates.
