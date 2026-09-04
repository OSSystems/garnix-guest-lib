{
  description = "NixOS module for servers deployed by garnix hosting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, microvm, ... }:
    {
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
