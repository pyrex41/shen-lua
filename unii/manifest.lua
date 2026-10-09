-- unii/manifest.lua -- build manifest: pinned revisions, toolchain, license,
-- bundle composition and format versions. Read by unii/build.lua, by the
-- host at boot (bundle/format versions) and by the tests. docs/MANIFEST.md
-- is the prose companion; keep the two in step.
return {
  app = "unii", -- provisional internal prefix (plan section 15)

  -- Rule bundle: load order of the typed Shen core. The bundle hash covers
  -- these files' bytes plus bundle_format.
  bundle_format = 1,
  core_files = {
    "arith.shen", "types.shen", "tree.shen", "view.shen",
    "jobs.shen", "transition.shen", "invariants.shen",
  },

  storage_format = 2, -- docs/contracts/storage.md
  codec_version = 1,  -- docs/contracts/codec.md

  shen_lua = {
    repo = "https://github.com/pyrex41/shen-lua",
    -- Base commit of this branch; the runtime outside unii/ must equal it.
    commit = "fc9757731580f77aad6b3b4cea53773261b36d44",
    commit_date = "2026-09-28T17:45:26-05:00",
    release = "0.11.1",
    kernel = "Shen 42 (S42 2026-08-25 refresh, see klambda/PROVENANCE.md)",
    license = "BSD-3-Clause (port, Reuben Brooks); BSD-3-Clause (kernel and tests, Mark Tarver)",
    lua_dependency = "lua == 5.1 (LuaJIT 2.1)",
  },

  gist = {
    url = "https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449",
    title = "UniiChat: one chat that never ends (optchat.md)",
    revision = "3c190e06f34aba0c69f49042c526093269604935",
    revision_date = "2026-10-08T01:58:24Z",
    file = "optchat.md",
    bytes = 19092,
    sha256 = "12f300f760af82bc07bc5201051d1267824ded09c9def8186e4f8144368038d8",
    git_blob = "4c09901baa3685852bf252cdb70ace81d01d6be5",
    raw_url = "https://gist.githubusercontent.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449/raw/3c190e06f34aba0c69f49042c526093269604935/optchat.md",
  },

  toolchain = {
    luajit = "LuaJIT 2.1; full suite verified on 2.1.1774638290 (nix develop ./unii, "
          .. "/nix/store/damwm6hccy1ryvjsjizfjrxf8rmcraia-luajit-2.1.1774638290) and on "
          .. "2.1.1703358377 (Ubuntu 24.04 package 2.1.0+git20231223.c525bcb+dfsg-1ubuntu0.1)",
    dev_shell = "nix develop ./unii (unii/flake.nix + unii/flake.lock: luajit, git, curl, gnumake, coreutils)",
    nixpkgs = "a5cc6f2c37bf518436dc8d1c288ccd0c43c2f4c4", -- same pin as the repo root flake.lock
    platform = "Linux x86_64 verified; Linux aarch64 and macOS supported by host/posix.lua flag tables but unverified",
    external_libraries = "none (SHA-256, codec and POSIX bindings are in-tree; LuaJIT FFI only)",
  },

  license = "BSD-3-Clause, same terms as the shen-lua port (LICENSE at the repo root)",
}
