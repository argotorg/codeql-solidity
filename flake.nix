{
  description = "CodeQL for Solidity — tree-sitter extractor and QL packs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        # The CodeQL CLI is redistributed under an unfree licence.
        config.allowUnfree = true;
      }));
    in
    {
      devShells = forAllSystems (pkgs:
        let
          python = pkgs.python3.withPackages (ps: [ ps.pyarrow ]);

          setup-extractor = pkgs.writeShellApplication {
            name = "setup-extractor";
            runtimeInputs = [ pkgs.cargo pkgs.git pkgs.coreutils ];
            text = ''
              root=$(git rev-parse --show-toplevel)
              cd "$root"

              cargo build --release
              bin="$root/target/release/codeql-extractor-solidity"

              # index-files.sh looks for the binary here, autobuild.sh under <platform>/.
              case "$(uname -s)-$(uname -m)" in
                Linux-x86_64)   platform=linux64 ;;
                Linux-aarch64)  platform=linux-arm64 ;;
                Darwin-arm64)   platform=darwin-arm64 ;;
                Darwin-x86_64)  platform=darwin-x64 ;;
                *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
              esac
              install -m755 "$bin" extractor-pack/tools/codeql-extractor-solidity
              install -D -m755 "$bin" "extractor-pack/tools/$platform/extractor"

              "$bin" generate \
                --dbscheme ql/lib/solidity.dbscheme \
                --library  ql/lib/codeql/solidity/ast/internal/TreeSitter.qll
              cp ql/lib/solidity.dbscheme extractor-pack/solidity.dbscheme

              echo "extractor built and dbscheme/QL library generated"
            '';
          };
          rust = [ pkgs.cargo pkgs.rustc pkgs.rustfmt pkgs.clippy pkgs.cargo-cyclonedx ];
        in
        {
          # Rust only, so CI's fmt/clippy/test job skips the ~1 GB codeql fetch.
          rust = pkgs.mkShell { packages = rust; };

          default = pkgs.mkShell {
            packages = rust ++ [
              pkgs.codeql
              # The tree-sitter extractor happily parses Solidity that does not
              # compile, so hand-written corpora under tests/ need a real check.
              pkgs.solc
              pkgs.rust-analyzer
              python
              pkgs.git
              setup-extractor
            ];

            shellHook = ''
              root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
              export CODEQL_EXTRACTOR_SOLIDITY_ROOT="$root/extractor-pack"
              if [ ! -f "$root/ql/lib/solidity.dbscheme" ]; then
                echo "build artifacts missing — run: setup-extractor"
              fi
            '';
          };
        });
    };
}
