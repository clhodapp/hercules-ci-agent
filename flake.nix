{
  description = "Hercules CI Agent";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-20.09";
  inputs.nixos-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-compat.url = "github:edolstra/flake-compat";
  inputs.flake-compat.flake = false;
  inputs.pre-commit-hooks-nix.url = "github:cachix/pre-commit-hooks.nix";
  inputs.pre-commit-hooks-nix.flake = false;

  outputs =
    inputs@{ self
    , nixpkgs
    , nixos-unstable
    , ...
    }:
    let
      lib = defaultNixpkgs.lib;
      filterMeta = defaultNixpkgs.lib.filterAttrs (k: v: k != "meta" && k != "recurseForDerivations");
      dimension = _name: attrs: f: lib.mapAttrs f attrs;

      defaultNixpkgs = nixos-unstable;
      defaultTarget = allTargets."nixos-unstable";
      testSuiteTarget = defaultTarget;

      allTargets =
        dimension "Nixpkgs version"
          {
            # Cachix 0.6 does not support GHC < 8.10
            # "nixos-20_09" = {
            #   nixpkgsSource = nixpkgs;
            # };
            "nixos-unstable" = {
              nixpkgsSource = nixos-unstable;
              isDevVersion = true;
            };
          }
          (
            _name: { nixpkgsSource, isDevVersion ? false }:
              dimension "System"
                {
                  "aarch64-linux" = {
                    # shellcheck was broken https://hercules-ci.com/github/hercules-ci/hercules-ci-agent/jobs/826
                    isDevSystem = false;
                  };
                  "x86_64-linux" = { };
                  "x86_64-darwin" = { };
                }
                (system: { isDevSystem ? true }:
                  let
                    pkgs =
                      import nixpkgsSource {
                        overlays = [ (import ./nix/make-overlay.nix inputs) dev-and-test-overlay ];
                        config = { };
                        inherit system;
                      };
                    dev-and-test-overlay =
                      self: pkgs:
                      {
                        testSuitePkgs = testSuiteTarget.${system};
                        devTools =
                          {
                            inherit (self.hercules-ci-agent-packages.internal.haskellPackages)
                              ghc
                              ghcid
                              stack
                              ;
                            inherit (pkgs)
                              jq
                              cabal2nix
                              nix-prefetch-git
                              niv
                              ;
                            inherit pkgs;
                          };
                      };
                  in
                  pkgs.recurseIntoAttrs
                    {
                      internal.pkgs = pkgs;
                      internal.haskellPackages = pkgs.hercules-ci-agent-packages.internal.haskellPackages;
                      inherit (pkgs.hercules-ci-agent-packages)
                        hercules-ci-cli
                        hercules-ci-api-swagger
                        ;
                      inherit (pkgs)
                        hercules-ci-agent
                        toTOML-test
                        ;
                    } // lib.optionalAttrs (isDevSystem && isDevVersion) {
                    inherit (pkgs)
                      pre-commit-check
                      devTools
                      ;
                  }
                )
          );

    in
    {
      # non-standard attribute
      ciChecks = lib.mapAttrs (k: v: v // { recurseForDerivations = true; }) allTargets;

      internal.pkgs = lib.mapAttrs (_sys: target: target.internal.pkgs) defaultTarget;

      packages =
        defaultNixpkgs.lib.mapAttrs
          (
            system: v:
              {
                inherit (v)
                  hercules-ci-agent
                  hercules-ci-cli
                  ;
              }
          )
          defaultTarget;

      overlay =
        final: prev: (import ./nix/make-overlay.nix inputs) final prev;

      # TODO
      # nixosModules.agent-service = { imports = [ ./module.nix ]; };
      nixosModules.agent-profile =
        { pkgs, ... }:
        {
          imports = [ ./for-upstream/default.nixos.nix ];

          # This module replaces what's provided by NixOS
          disabledModules = [ "services/continuous-integration/hercules-ci-agent/default.nix" ];

          config = {
            services.hercules-ci-agent.package = self.packages.${pkgs.system}.hercules-ci-agent;
          };
        };

      defaultApp = lib.mapAttrs (k: v: v.hercules-ci-cli) self.packages;

      defaultTemplate = self.templates.nixos;
      templates = {
        nixos = {
          path = ./templates/nixos;
          description = "A NixOS configuration with Hercules CI Agent";
        };
      };

      devShell = lib.mapAttrs
        (
          system: { internal, devTools, pre-commit-check, ... }:
            internal.pkgs.mkShell {
              NIX_PATH = "nixpkgs=${internal.pkgs.path}";
              nativeBuildInputs =
                [
                  (internal.pkgs.writeScriptBin "stack" ''
                    #!/bin/sh
                    export PATH="${internal.haskellPackages.stack}/bin:$PATH"
                    if test -n "''${HIE_BIOS_OUTPUT:-}"; then
                        echo | stack "$@"

                        # Internal packages appear in -package flags for some
                        # reason, unlike normal packages. This filters them out.
                        sed -e 's/^-package=z-.*-z-.*$//' \
                            -e 's/^-package-id=hercules-ci-agent.*$//' \
                            -i $HIE_BIOS_OUTPUT

                        # To support the CPP in Hercules.Agent.StoreFFI
                        echo '-DGHCIDE=1' >>$HIE_BIOS_OUTPUT

                        # Hack to include the correct snapshot directory
                        echo "-package-db=$(dirname $(stack path --snapshot-doc-root))/pkgdb" >> $HIE_BIOS_OUTPUT
                    else
                        exec stack "$@"
                    fi
                  '')
                  devTools.ghcid
                  devTools.jq
                  devTools.cabal2nix
                  devTools.nix-prefetch-git
                  internal.haskellPackages.ghc
                  internal.haskellPackages.ghcide
                  internal.haskellPackages.haskell-language-server
                ];
              inherit (pre-commit-check) shellHook;
            }
        )
        defaultTarget;
    };
}
