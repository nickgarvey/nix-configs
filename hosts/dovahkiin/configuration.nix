{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
    ../../modules/esp-prog-udev.nix
    ../../modules/wifi.nix
    # ../../modules/vector-db-learning.nix  # disabled: arxiv pins requests~=2.32, conflicts with nixpkgs 2.33
    ../../modules/nix-remote-builder-client.nix
    ../../modules/upower-overlay.nix
    ../../modules/opencloud-desktop.nix
    ./printer.nix
    inputs.pi-nix.nixosModules.default
  ];

  # pi reads its env file as the ngarvey user, so the secret must be owned by it.
  sops.secrets.deepseek-api-key = {
    sopsFile = ../../secrets/deepseek.yaml;
    owner = "ngarvey";
  };

  programs.pi.coding-agent = {
    enable = true;
    users = [ "ngarvey" ];
    environment.DEEPSEEK_API_KEY = config.sops.secrets.deepseek-api-key.path;
    extraArgs = [ "--provider" "deepseek" "--model" "deepseek-v4-pro" ];
  };

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "talos";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "amdgpu.sg_display=0"
    "amdgpu.dcdebugmask=0x410"
    "amdgpu.cwsr_enable=0"
  ];

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.hostName = "dovahkiin";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

  # The MT7925 (RZ717) Wi-Fi 7 firmware mailbox hangs when the PCIe link
  # enters ASPM L1, causing "Message ... timeout" firmware resets and dropped
  # connections. Disable L1 ASPM for just this device.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x0717", ATTR{link/l1_aspm}="0"
  '';

  # COSMIC display manager and desktop
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

  services.fwupd.enable = true;

  services.fprintd.enable = true;
  security.pam.services.login.fprintAuth = true;
  security.pam.services.sudo.fprintAuth = true;
  security.pam.services.cosmic-greeter.fprintAuth = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  users.users.ngarvey.packages = with pkgs; [
    signal-desktop
    vlc
    openmw
    # See UPSTREAMABLE_FIXES.md: orca-slicer's wrapper sets GST_PLUGIN_SYSTEM_PATH_1_0
    # but not GST_PLUGIN_SCANNER, causing playbin discovery to fail and segfaulting
    # wxMediaCtrl2 when opening the Monitor (printer camera) tab.
    (orca-slicer.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ../../patches/orca-slicer-null-checks.patch ];
      preFixup = (old.preFixup or "") + ''
        gappsWrapperArgs+=(
          --set GST_PLUGIN_SCANNER "${gst_all_1.gstreamer}/libexec/gstreamer-1.0/gst-plugin-scanner"
        )
      '';
    }))
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "yes";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  system.stateVersion = "25.11";
}
