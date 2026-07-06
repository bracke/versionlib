# AGENTS.md

This crate enforces GNAT 15 through Alire with `gnat_native = "=15.2.1"` in
every active manifest. Do not run plain system GNAT, GPRBuild, GNATprove,
GNATdoc, or related `gnat*` tools from `PATH`; use `alr exec -- ...` for
compiler, builder, prover, and documentation tools.

Before building or testing, run:

```sh
alr exec -- gnatls --version
```

The command must report `GNATLS 15.x`.

Additional agent guidance for this crate lives in [CLAUDE.md](CLAUDE.md) — the
same content applies regardless of which AI coding tool you use.
