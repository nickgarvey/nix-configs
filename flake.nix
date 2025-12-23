{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    cursor-remote-node = {
      url = "path:./modules/cursor-remote-node";
    };
  };
  outputs = inputs@{ self, nixpkgs, disko, sops-nix, cursor-remote-node, ... }:
  let
    k3sHelpers = import ./lib/k3s-nodes.nix { inherit nixpkgs disko sops-nix inputs; };
    # Generate the k3s nodes for 1 - 3
    # Actual configs for these nodes are in hosts/
    k3sNodes = k3sHelpers.generateK3sNodes [ 1 2 3 ];

    pkgs = import nixpkgs { system = "x86_64-linux"; };
  in
  {
    # Custom packages
    packages.x86_64-linux = {
      triplea = pkgs.callPackage ./pkgs/triplea.nix { };
    };

    # Development shells
    devShells.x86_64-linux = {
      makernexus = import ./devshells/makernexus.nix { inherit pkgs; };
    };

    # These are all NixOS configurations
    nixosConfigurations = {
      # Desktop
      desktop-nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/desktop-nixos/configuration.nix
          cursor-remote-node.nixosModules.cursor-remote-node
        ];
      };

      # G16 Laptop
      g16-laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/g16-laptop/configuration.nix
        ];
      };
    }
    # K3s nodes
    // k3sNodes;
  };
}
