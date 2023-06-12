{
  description = "nixos-generators - one config, multiple formats";

  # Lib dependency
  inputs.nixlib.url = "github:nix-community/nixpkgs.lib";

  # Bin dependency
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
    nixlib,
  }:
  # Library modules (depend on nixlib)
    {
      # export all generator formats in ./formats
      nixosModules = nixlib.lib.mapAttrs' (file: _: {
        name = nixlib.lib.removeSuffix ".nix" file;
        # The exported module should include the internal format* options
        value.imports = [(./formats + "/${file}") ./format-module.nix];
      }) (builtins.readDir ./formats);

      # example usage in flakes:
      #   outputs = { self, nixpkgs, nixos-generators, ...}: {
      #     vmware = nixos-generators.nixosGenerate {
      #       system = "x86_64-linux";
      #       modules = [./configuration.nix];
      #       format = "vmware";
      #   };
      # }

      nixosGenerate = {
        pkgs ? null,
        lib ? nixpkgs.lib,
        format,
        system ? null,
        specialArgs ? {},
        modules ? [],
        customFormats ? {},
        nixosSystem ? null  
      }: let
        extraFormats =
          lib.mapAttrs' (
            name: value:
              lib.nameValuePair
              name
              (value
                // {
                  imports = value.imports or [] ++ [./format-module.nix];
                })
          )
          customFormats;
        formatModule = builtins.getAttr format (self.nixosModules // extraFormats);        
        image = if nixosSystem != null
                then nixosSystem.extendModules { modules = [ formatModule ] ++ modules; }
                else nixpkgs.lib.nixosSystem {
                  inherit pkgs specialArgs;
                  system =
                    if system != null
                    then system
                    else pkgs.system;
                  lib =
                    if lib != null
                    then lib
                    else pkgs.lib;
                  modules =
                    [
                      formatModule
                    ]
                    ++ modules;
                };
      in
        image.config.system.build.${image.config.formatAttr};
    }
    //
    # Binary and Devshell outputs (depend on nixpkgs)
    (
      let
        forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "x86_64-darwin" "i686-linux" "aarch64-linux" "aarch64-darwin"];
      in {
        formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

        packages = forAllSystems (system: let
          pkgs = nixpkgs.legacyPackages."${system}";
        in rec {
          default = nixos-generate;
          nixos-generators =
            nixpkgs.lib.warn ''

              Deprecation note from: github:nix-community/nixos-generators

              Was renamed:

              Was: nixos-generators.packages.${system}.nixos-generators
              Now: nixos-generators.packages.${system}.nixos-generate

              Plase adapt your references
            ''
            nixos-generate;
          nixos-generate = pkgs.stdenv.mkDerivation {
            name = "nixos-generate";
            src = ./.;
            meta.description = "Collection of image builders";
            nativeBuildInputs = with pkgs; [makeWrapper];
            installFlags = ["PREFIX=$(out)"];
            postFixup = ''
              wrapProgram $out/bin/nixos-generate \
                --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [jq coreutils findutils])}
            '';
          };
        });

        checks = forAllSystems (system: {
          inherit
            (self.packages.${system})
            nixos-generate
            ;
          is-formatted = import ./checks/is-formatted.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };
        });

        devShells = forAllSystems (system: let
          pkgs = nixpkgs.legacyPackages."${system}";
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [jq coreutils findutils];
          };
        });

        # Make it runnable with `nix run`
        apps = forAllSystems (system: let
          nixos-generate = {
            type = "app";
            program = "${self.packages."${system}".nixos-generate}/bin/nixos-generate";
          };
        in {
          inherit nixos-generate;

          # Nix >= 2.7 flake output schema uses `apps.<system>.default` instead
          # of `defaultApp.<system>` to signify the default app (the thing that
          # gets run with `nix run . -- <args>`)
          default = nixos-generate;
        });

        # legacy flake schema compat
        defaultApp = forAllSystems (system: self.apps."${system}".nixos-generate);
        defaultPackage =
          forAllSystems (system: self.packages.${system}.default);
        devShell = forAllSystems (system: self.devShells.${system}.default);
      }
    );
}
