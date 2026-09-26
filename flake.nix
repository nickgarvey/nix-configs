{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Stable release for packages whose version should only move deliberately.
    # Currently Ceph (modules/services/ceph.nix).
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";

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

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Temporal workers.
    temporal-workflows = {
      url = "github:nickgarvey/temporal-workflows";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pi-nix = {
      url = "github:lukasl-dev/pi.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # LAN inventory page, packaged in the homelab-nixpkgs repo.
    lan-table = {
      url = "github:nickgarvey/homelab-nixpkgs?dir=lan-table";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ThinkRail, packaged in the homelab-nixpkgs repo.
    thinkrail = {
      url = "github:nickgarvey/homelab-nixpkgs?dir=thinkrail";
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
  outputs = inputs@{ self, nixpkgs, disko, sops-nix, helium-browser, nixos-hardware, microvm, claude-code-nix, nixos-raspberrypi, cartographer3d-plugin, ... }:
  let
    k3sHelpers = import ./lib/k3s-nodes.nix { inherit nixpkgs disko sops-nix inputs; };
    # Generate the k3s nodes
    # Actual configs for these nodes are in hosts/
    k3sNodes = k3sHelpers.generateK3sNodes [ "fus" "ro" "dah" "joor" "zah" "frul" ];

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
      # Workstation (MSI X870E / 9950X3D / RTX 5090)
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

      # TV PC (ASUS Zenbook S 16, broken internal panel, drives the living-room TV)
      guevenne = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          nixos-hardware.nixosModules.common-cpu-amd-pstate
          nixos-hardware.nixosModules.common-pc-laptop
          nixos-hardware.nixosModules.common-pc-laptop-ssd
          ./hosts/guevenne/configuration.nix
          ./hosts/guevenne/disk-config.nix
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

      # Framework Desktop
      wabbajack = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
          sops-nix.nixosModules.sops
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

      # Nelkir: Raspberry Pi 4 Model B acting as an HDMI-CEC controller for the
      # TV. Plain nixpkgs rather than nixos-raspberrypi (which skyforge uses):
      # BCM2711 is fully mainlined, and the stock aarch64 kernel already ships
      # DRM_VC4_HDMI_CEC, so the vendor stack has nothing to add here.
      nelkir = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/nelkir/configuration.nix
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

      # Same live system, as PXE netboot artifacts served from lydia
      live-netboot = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/live-iso/netboot.nix
        ];
      };
    }
    # K3s nodes
    // k3sNodes;
  };
}
