{ config, lib, pkgs, inputs, k3sVmNode1Modules, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/k3s-hosts.nix
    ../../modules/containers/frigate.nix
    ../../modules/microvm/smb.nix
  ];

  networking.hostName = "microatx";

  sops.defaultSopsFile = ../../secrets/microatx.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  # --- Boot ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
    "split_lock_detect=off"
  ];

  networking.nftables.enable = true;

  # --- Networking ---
  # Bridge for VMs/containers to get LAN access (IPv6 auto-derived from lan-hosts.nix)
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp5s0";
    ipv4 = {
      address = "10.28.12.108/16";
      gateway = "10.28.0.1";
    };
  };
  # Incus loads br_netfilter which causes bridge traffic (including ARP) to
  # pass through netfilter, breaking DHCP and host connectivity on vmbr0.
  # Disable bridge netfilter since we use vmbr0 directly, not an Incus NAT bridge.
  networking.firewall.trustedInterfaces = [ "vmbr0" ];
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;
  };


  # Tailscale
  services.tailscale.enable = true;

  # --- Storage: btrfs ---
  # SATA mirror (2x 8TB Seagate) — slow/bulk storage
  fileSystems."/slow/backups" = {
    device = "/dev/disk/by-label/slow";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@backups" "nofail" ];
  };

  # Samsung 980 PRO NVMe — fast tier
  fileSystems."/fast/media" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "subvol=@media" "nofail" ];
  };
  fileSystems."/fast/frigate" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@frigate" "nofail" ];
  };
  fileSystems."/fast/incus" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "subvol=@incus" "nofail" ];
  };

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/fast/media" "/fast/frigate" ];
  };

  # btrbk snapshots
  services.btrbk.instances.data = {
    onCalendar = "hourly";
    settings = {
      snapshot_preserve_min = "2d";
      snapshot_preserve = "14d";
      volume."/slow" = {
        subvolume.backups = { snapshot_dir = ".snapshots"; };
      };
      volume."/fast" = {
        subvolume.media = { snapshot_dir = ".snapshots"; };
      };
    };
  };

  # --- Incus ---
  users.users.ngarvey.extraGroups = [ "incus-admin" ];
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    preseed = {
      config = {
        "core.https_address" = ":8443";
      };
      storage_pools = [
        {
          name = "default";
          driver = "btrfs";
          config = {
            source = "/fast/incus";
          };
        }
      ];
    };
  };

  # --- k3s worker microVM ---
  # Declarative microvm: built from the same modules as nixosConfigurations.k3s-vm-node-1
  # so the host-rebuild and direct deploy.py paths stay in sync.
  systemd.tmpfiles.rules = [
    "d /var/lib/microvms/k3s-vm-node-1 0755 root root - -"
    "d /var/lib/microvms/k3s-vm-node-1/sops 0700 root root - -"
  ];

  microvm.vms.k3s-vm-node-1 = {
    specialArgs = { inherit inputs; };
    config.imports = k3sVmNode1Modules;
  };

  # Attach the VM's tap interface to vmbr0 (mirrors the smb VM pattern).
  systemd.services.microvm-k3s-vm-node-1-bridge = {
    description = "Attach k3s-vm-node-1 microvm tap to vmbr0";
    after = [ "microvm-tap-interfaces@k3s-vm-node-1.service" ];
    requires = [ "microvm-tap-interfaces@k3s-vm-node-1.service" ];
    before = [ "microvm@k3s-vm-node-1.service" ];
    wantedBy = [ "microvms.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip link set vm-k3s1 master vmbr0";
    };
  };

  # --- SMB (microvm) ---
  microvm-smb = {
    hostBridge = "vmbr0";
    address = "10.28.12.110/16";
    gateway = "10.28.0.1";
    mac = "02:00:00:00:01:10";
    shares = [
      { name = "media"; path = "/fast/media"; owner = "media"; }
    ];
  };

  # --- Frigate NVR (nspawn container) ---
  nspawn.frigate = {
    hostBridge = "vmbr0";
    localAddress = "10.28.12.109/24";
    dataPath = "/fast/frigate/data";
    cachePath = "/fast/frigate/cache";
  };
  networking.firewall.allowedTCPPorts = [ 8443 ];

  environment.systemPackages = with pkgs; [
    ethtool
  ];

  system.stateVersion = "25.05";
}
