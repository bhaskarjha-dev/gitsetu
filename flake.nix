{
  description = "Zero-trust multi-account Git identity orchestrator (development branch)";

  inputs = {
    # Pinned to an immutable revision; flake.lock records the same input.
    nixpkgs.url = "github:NixOS/nixpkgs/8825bebf6324e0579d012936eff73379af284b6d";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          runtimeInputs = with pkgs; [
            bash
            git
            openssh
            openssl
            coreutils
            gnugrep
            gnused
            gawk
            findutils
            which
          ];
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "gitsetu";
            # The executable reports 1.1.0 while this branch is withheld.
            version = "1.1.0-dev";
            upstreamVersion = "1.1.0";
            src = ./.;

            strictDeps = true;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = runtimeInputs;

            installPhase = ''
              mkdir -p $out/bin $out/share/gitsetu/lib $out/share/bash-completion/completions
              cp -r lib/* $out/share/gitsetu/lib/
              cp gitsetu $out/share/gitsetu/gitsetu
              cp lib/completion.sh $out/share/bash-completion/completions/gitsetu
              chmod +x $out/share/gitsetu/gitsetu

              makeWrapper $out/share/gitsetu/gitsetu $out/bin/gitsetu \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}
              ln -s gitsetu $out/bin/git-setu
            '';

            passthru = {
              releaseState = "development";
              publicRelease = false;
            };

            meta = with pkgs.lib; {
              description = "Zero-trust multi-account Git identity orchestrator";
              homepage = "https://gitsetu.bhaskarjha.dev";
              license = licenses.mit;
              platforms = platforms.unix;
              mainProgram = "gitsetu";
            };
          };
        });

      checks = forAllSystems (system:
        let
          package = self.packages.${system}.default;
          pkgs = nixpkgsFor.${system};
        in {
          aliases = pkgs.runCommand "gitsetu-alias-check" { } ''
            test -x $package/bin/gitsetu
            test -L $package/bin/git-setu
            $package/bin/gitsetu --version | grep -F 'gitsetu v1.1.0'
          '';
        });
    };
}
