# Build manifest

The machine-readable copy is `unii/manifest.lua`. The build and the tests
read that file, so update it first and then keep this page in step.

## Pinned revisions

| Item | Value |
|---|---|
| shen-lua | `fc9757731580f77aad6b3b4cea53773261b36d44` (merge of PR #71, release 0.11.1, 2026-09-28). This is the base commit of this branch. |
| Shen kernel | Shen 42 (S42 2026-08-25 refresh; see `klambda/PROVENANCE.md`) |
| UniiChat gist | revision `3c190e06f34aba0c69f49042c526093269604935` (2026-10-08T01:58:24Z), file `optchat.md`, 19,092 bytes |
| gist sha256 | `12f300f760af82bc07bc5201051d1267824ded09c9def8186e4f8144368038d8` (git blob `4c09901baa3685852bf252cdb70ace81d01d6be5`) |
| nixpkgs | `a5cc6f2c37bf518436dc8d1c288ccd0c43c2f4c4`, the same pin as the repository root `flake.lock`, with the same narHash |

`unii/build.lua` refuses to build if any tracked or untracked file outside
`unii/` differs from the pinned shen-lua commit. `test_boundary.lua`
re-downloads the gist at the pinned revision and checks its size, sha256
and git blob id. Set `UNII_OFFLINE=1` to skip that download.

## Toolchain

| Item | Value |
|---|---|
| Runtime | LuaJIT 2.1. No other dependencies: SHA-256, the codec and the POSIX bindings are in-tree and use the LuaJIT FFI. |
| Verified with Nix | LuaJIT 2.1.1774638290 from `nix develop ./unii` (`/nix/store/damwm6hccy1ryvjsjizfjrxf8rmcraia-luajit-2.1.1774638290`) |
| Verified on Ubuntu | LuaJIT 2.1.1703358377, Ubuntu 24.04 package `2.1.0+git20231223.c525bcb+dfsg-1ubuntu0.1` |
| Platform | Linux x86_64 verified. `host/posix.lua` has flag tables for Linux aarch64 and macOS, but neither has been run. |
| Tests also use | `git` (the pinning checks and the gist blob id) and `curl` (the gist download) |

## Rule bundle

| Item | Value |
|---|---|
| Files, in load order | `core/arith.shen types.shen tree.shen view.shen jobs.shen transition.shen invariants.shen` |
| Bundle hash | sha256 over the files' bytes and `bundle_format`. At the time of writing: `a76e9882bfc2b45728c33b2d97bc2b8e3755b9422ab70e8ddb78adb33878a755` |
| Formats | `bundle_format` 1, `storage_format` 1, `codec_version` 1 |

`unii build`, which also runs at the start of `luajit unii/test/run.lua`,
does the following:

1. Loads the bundle under `(tc +)` with the fasl cache off
   (`SHEN_FASL=off`), so the kernel typechecker really runs.
2. Checks that an ill-typed fixture is rejected.
3. Writes `unii/build/bundle.stamp`.

At boot, the host refuses any bundle whose hash does not match the stamp. A
journal written under a different bundle is refused when it is opened.

## License

BSD-3-Clause. The shen-lua port is BSD-3-Clause (Reuben Brooks). The Shen
kernel and its tests are BSD-3-Clause (Mark Tarver). See `LICENSE` at the
repository root. The gist is used as a design source and test oracle, and
none of its text is vendored.
