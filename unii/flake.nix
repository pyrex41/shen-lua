{
  description = "unii development environment (pinned; see unii/manifest.lua)";

  # Same nixpkgs revision as the repository's root flake.lock at the pinned
  # shen-lua commit.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a5cc6f2c37bf518436dc8d1c288ccd0c43c2f4c4";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.luajit pkgs.git pkgs.curl pkgs.gnumake pkgs.coreutils ];
          shellHook = ''
            echo "unii dev shell: $(luajit -v)"
            echo "run all checks: luajit unii/test/run.lua   (from the repository root)"
          '';
        };
      });
    };
}
