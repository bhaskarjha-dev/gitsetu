{
  description = "Zero-trust multi-account Git identity orchestrator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "gitsetu";
            version = "1.0.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ pkgs.bash pkgs.git pkgs.openssh ];

            installPhase = ''
              mkdir -p $out/bin $out/share/gitsetu/lib
              cp -r lib/* $out/share/gitsetu/lib/
              cp gitsetu $out/share/gitsetu/gitsetu
              chmod +x $out/share/gitsetu/gitsetu

              makeWrapper $out/share/gitsetu/gitsetu $out/bin/gitsetu \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bash pkgs.git pkgs.openssh pkgs.coreutils ]}

              ln -s $out/bin/gitsetu $out/bin/git-setu
            '';

            meta = with pkgs.lib; {
              description = "Zero-trust multi-account Git identity orchestrator";
              homepage = "https://gitsetu.bhaskarjha.dev";
              license = licenses.mit;
              platforms = platforms.unix;
              mainProgram = "gitsetu";
            };
          };
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/gitsetu";
        };
      });
    };
}
