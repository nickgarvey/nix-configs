{ config, lib, pkgs, inputs, ... }:
{
  options.commonConfig = {
    commonPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Base set of packages to be installed on all systems.";
    };
  };

  config = {
    commonConfig.commonPackages = with pkgs; [
      btop
      file
      neovim
      parallel
      pciutils
      ripgrep
      tmux
      unzip
      usbutils
      wget
    ];
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      extra-substituters = [ "https://cache.nixos-cuda.org" ];
      extra-trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
    };

    environment.variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };

    programs.git = {
      enable = true;
      lfs.enable = true;
    };

    services.openssh.enable = true;
    security.pki.certificateFiles = [
      ../public_certs/Garvey_Home_Root_CA.crt
      ../public_certs/Garvey_Home_Intermediate_CA.crt
    ];

    nix.optimise.automatic = true;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    users.users.ngarvey = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbmansQ84WUYb3frRU8CKPrZb6DdrfnHavtebK6JF5OQdK3C9nK6Xzoz6YKN4zISv7Vx+o7IReJNwjwV6JrUuOrcavBjTvMCgjotdnlYsk9gpuQjDd0MqHD6WdvuDSWxceKbCIP+6AGrVHKJRycFuLkF49f0fnDDy61+w0NWE3t/U1i2yiWOF+SlwvCxlvMYPFYkMWYarmi2Z3MXV1JCIEGwuv7nTQs/o1EEIk9G/YcjhiRMBRvYp6JaTJIXlpVeGpDp9K79VFWCSm6LdQENSWGwrfBeipdq9qRYHulbzTjWtF3LCcYQUm0Z8ZIIhnaqcqIHgFnYMSB79m/XhvKK3T"
      ];
    };
    security.sudo.wheelNeedsPassword = false;
    networking.networkmanager.enable = true;
  };
}
