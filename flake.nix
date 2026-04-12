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
      url = "path:/home/ngarvey/homelab/homelab-nixpkgs/llama-cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@{ self, nixpkgs, disko, sops-nix, helium-browser, nixos-hardware, microvm, llama-cpp, ... }:
  let
    k3sHelpers = import ./lib/k3s-nodes.nix { inherit nixpkgs disko sops-nix inputs; };
    # Generate the k3s nodes for 1 - 3
    # Actual configs for these nodes are in hosts/
    k3sNodes = k3sHelpers.generateK3sNodes [ 1 2 3 ];

    pkgs = import nixpkgs { system = "x86_64-linux"; };

    # Shared module list for the k3s-vm-node-1 microVM. Used both by the
    # top-level nixosConfiguration (deploy.py path) and by microatx's
    # microvm.vms.k3s-vm-node-1 (host-rebuild path) so they stay in sync.
    # The top-level entry additionally needs microvm.nixosModules.microvm;
    # microvm.vms.* injects that automatically on the host side.
    k3sVmNode1Modules = [
      sops-nix.nixosModules.sops
      ./modules/k3s-hosts.nix
      ./hosts/k3s-vm-node-1/configuration.nix
      ./hosts/k3s-vm-node-1/microvm.nix
    ];

    # Shared module lists for k3s-vm-server-{1,2,3} microVMs (temporary control
    # plane for cluster migration). Same pattern as k3sVmNode1Modules.
    mkK3sVmServerModules = n: [
      sops-nix.nixosModules.sops
      ./modules/k3s-hosts.nix
      ./hosts/k3s-vm-server-${toString n}/configuration.nix
      ./hosts/k3s-vm-server-${toString n}/microvm.nix
    ];
    k3sVmServer1Modules = mkK3sVmServerModules 1;
    k3sVmServer2Modules = mkK3sVmServerModules 2;
    k3sVmServer3Modules = mkK3sVmServerModules 3;
  in
  {
    # Development shells
    devShells.x86_64-linux = {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          python312
        ];
      };

      makernexus = import ./devshells/makernexus.nix { inherit pkgs; };
    };

    # Checks
    checks.x86_64-linux = {
      deploy-tests = pkgs.runCommand "deploy-tests" {
        nativeBuildInputs = [ pkgs.python312 ];
      } ''
        cp ${./scripts/deploy.py} deploy.py
        cp ${./scripts/test_deploy.py} test_deploy.py
        python3 -m unittest test_deploy -v
        touch $out
      '';
    };

    # These are all NixOS configurations
    nixosConfigurations = {
      # Desktop
      desktop-nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/desktop-nixos/configuration.nix
        ];
      };

      # Framework 13 Laptop
      framework13-laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          nixos-hardware.nixosModules.framework-amd-ai-300-series
          ./hosts/framework13-laptop/configuration.nix
          ./hosts/framework13-laptop/disk-config.nix
        ];
      };

      # Router
      router = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./hosts/router/configuration.nix
          ./hosts/router/disk-config.nix
        ];
      };

      # Framework Desktop (llama-cpp inference server)
      framework = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
          ./hosts/framework/configuration.nix
          ./hosts/framework/disk-config.nix
        ];
      };

      # k3s worker running as a microVM on microatx.
      # See hosts/k3s-vm-node-1/microvm.nix for the microvm hardware bits.
      k3s-vm-node-1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [ microvm.nixosModules.microvm ] ++ k3sVmNode1Modules;
      };

      # Temporary k3s server VMs for cluster migration (hosted on microatx)
      k3s-vm-server-1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [ microvm.nixosModules.microvm ] ++ k3sVmServer1Modules;
      };
      k3s-vm-server-2 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [ microvm.nixosModules.microvm ] ++ k3sVmServer2Modules;
      };
      k3s-vm-server-3 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [ microvm.nixosModules.microvm ] ++ k3sVmServer3Modules;
      };

      # Microatx server (replaces Proxmox on minicheese)
      microatx = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs k3sVmServer1Modules k3sVmServer2Modules k3sVmServer3Modules; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          microvm.nixosModules.host
          ./hosts/microatx/configuration.nix
          ./hosts/microatx/disk-config.nix
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
