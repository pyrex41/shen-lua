{
  description = "Shen 42 on LuaJIT";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));
    in {
      packages = eachSystem (_system: pkgs: rec {
        shen-lua = pkgs.stdenvNoCC.mkDerivation {
          pname = "shen-lua";
          version = "0.11.0-dev";
          src = self;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          nativeCheckInputs = [ pkgs.luajit ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            export HOME="$TMPDIR"
            make test LUA=${pkgs.luajit}/bin/luajit
            runHook postCheck
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/shen-lua" "$out/bin"
            cp -R . "$out/share/shen-lua/"
            makeWrapper ${pkgs.luajit}/bin/luajit "$out/bin/shen" \
              --add-flags "$out/share/shen-lua/bin/shen"
            runHook postInstall
          '';
        };

        default = shen-lua;
      });

      apps = eachSystem (system: _pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/shen";
          meta.description = "Run Shen 42 on LuaJIT";
        };
      });

      checks = eachSystem (system: _pkgs: {
        default = self.packages.${system}.default;
      });

      devShells = eachSystem (_system: pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.luajit pkgs.gnumake ];
        };
      });
    };
}
