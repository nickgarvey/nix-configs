{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    helium-browser = {
      url = "github:ominit/helium-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    llama-cpp = {
      url = "github:nickgarvey/homelab-nixpkgs?dir=llama-cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pi-nix = {
      url = "github:lukasl-dev/pi.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    # Cartographer V3 klipper plugin (the current/active one — newer than
    # the legacy Cartographer3D/cartographer-klipper loose-script repo,
    # this is the pip-distributed proper python package that the official
    # docs target). Consumed via overlay on services.klipper.package in
    # hosts/skyforge/configuration.nix.
    cartographer3d-plugin = {
      url = "github:Cartographer3D/cartographer3d-plugin";
      flake = false;
    };
  };
  outputs = inputs@{ self, nixpkgs, disko, sops-nix, helium-browser, nixos-hardware, microvm, llama-cpp, claude-code-nix, nixos-raspberrypi, cartographer3d-plugin, ... }:
  let
    k3sHelpers = import ./lib/k3s-nodes.nix { inherit nixpkgs disko sops-nix inputs; };
    # Generate the k3s nodes
    # Actual configs for these nodes are in hosts/
    k3sNodes = k3sHelpers.generateK3sNodes [ "fus" "ro" "dah" ];

    pkgs = import nixpkgs { system = "x86_64-linux"; };

    # The deploy binary, built from ./deployment. buildGoModule runs `go test`
    # as part of the build, so this derivation is also the test check.
    deployPkg = pkgs.buildGoModule {
      pname = "deploy";
      version = "0.1.0";
      src = ./deployment;
      vendorHash = null; # no external deps
    };

  in
  {
    # Development shells
    devShells.x86_64-linux = {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          python312
          go
          deployPkg
        ];
      };

      makernexus = import ./devshells/makernexus.nix { inherit pkgs; };
    };

    # Packages
    packages.x86_64-linux.deploy = deployPkg;

    # Checks
    checks.x86_64-linux = {
      deploy-tests = deployPkg;
    };

    # These are all NixOS configurations
    nixosConfigurations = {
      # Desktop
      talos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./hosts/talos/configuration.nix
          ./hosts/talos/disk-config.nix
        ];
      };

      # Framework 13 Laptop
      dovahkiin = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          nixos-hardware.nixosModules.framework-amd-ai-300-series
          ./hosts/dovahkiin/configuration.nix
          ./hosts/dovahkiin/disk-config.nix
        ];
      };

      # Router
      dragonsreach = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./hosts/dragonsreach/configuration.nix
          ./hosts/dragonsreach/disk-config.nix
        ];
      };

      # Framework Desktop (llama-cpp inference server)
      wabbajack = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
          ./hosts/wabbajack/configuration.nix
          ./hosts/wabbajack/disk-config.nix
        ];
      };

      # Skyforge: Raspberry Pi 5 running Klipper for the Voron Trident printer.
      # Uses nvmd/nixos-raspberrypi's pinned nixpkgs (NOT our top-level
      # `nixpkgs` input) because nvmd's vendor-kernel/firmware overlays expect
      # matching userspace versions — mixing nixpkgs versions trips the
      # "kernel module and userspace tooling versions are not matching"
      # assertion (wireguard/zfs/etc).
      skyforge = nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs // { inherit inputs; };
        modules = [
          sops-nix.nixosModules.sops
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          nixos-raspberrypi.nixosModules.sd-image
          ./hosts/skyforge/configuration.nix
        ];
      };

      # Lydia server
      lydia = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          microvm.nixosModules.host
          ./hosts/lydia/configuration.nix
          ./hosts/lydia/disk-config.nix
        ];
      };

      # Live boot ISO for installation and rescue
      live-iso = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/live-iso/configuration.nix
        ];
      };
    }
    # K3s nodes
    // k3sNodes;
  };
}
