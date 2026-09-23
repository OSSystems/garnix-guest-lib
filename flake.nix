{
  description = "NixOS module for servers deployed by garnix hosting";

  inputs = {
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";

      inputs.nixpkgs.follows = "nixpkgs";

    };

    pedantix = {
      url = "github:Swarsel/pedantix";

      inputs.nixpkgs.follows = "nixpkgs";

    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      microvm,
      nixpkgs,
      pedantix,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      treefmtFor = forAllSystems (
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          imports = [ pedantix.treefmtModules.default ];
          projectRootFile = "flake.nix";
          programs.pedantix.enable = true;
        }
      );
    in
    {
      formatter = forAllSystems (system: treefmtFor.${system}.config.build.wrapper);

      checks = forAllSystems (system: {
        formatting = treefmtFor.${system}.config.build.check self;
      });

      nixosModules = {
        garnix-guest = {
          imports = [
            microvm.nixosModules.microvm
            ./guest-profile.nix
          ];
        };
        default = self.nixosModules.garnix-guest;
      };
    };
}
