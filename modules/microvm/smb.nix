{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.microvm-smb;

  shareType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Share name as seen by SMB clients.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        description = "Host path to share.";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        description = "Owner user/group for force user/group. Files created over SMB will be owned by this user.";
      };
    };
  };

in
{
  options.microvm-smb = {
    hostBridge = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge interface for the VM network.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 address with prefix length for the SMB VM (e.g. \"10.28.12.110/16\").";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      description = "Default gateway for the SMB VM.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      description = "MAC address for the VM's network interface.";
    };

    shares = lib.mkOption {
      type = lib.types.listOf shareType;
      description = "List of SMB shares to expose.";
    };
  };

  config = {
    # Attach the VM's tap interface to the host bridge
    systemd.services.microvm-smb-bridge = {
      description = "Attach SMB microvm tap to bridge";
      after = [ "microvm-tap-interfaces@smb.service" ];
      requires = [ "microvm-tap-interfaces@smb.service" ];
      before = [ "microvm@smb.service" ];
      wantedBy = [ "microvms.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip link set vm-smb master ${cfg.hostBridge}";
      };
    };

    microvm.vms.smb = {
      config = { config, pkgs, lib, ... }: {
        imports = [ inputs.microvm.nixosModules.microvm ];

        microvm = {
          hypervisor = "qemu";
          vcpu = 1;
          mem = 512;

          interfaces = [{
            type = "tap";
            id = "vm-smb";
            mac = cfg.mac;
          }];

          shares = [
            {
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              tag = "ro-store";
              proto = "virtiofs";
            }
          ]
          ++ map (s: {
            source = s.path;
            mountPoint = "/srv/${s.name}";
            tag = s.name;
            proto = "virtiofs";
          }) cfg.shares;
        };

        users.groups = lib.listToAttrs (map (s: {
          name = s.owner;
          value = {};
        }) cfg.shares);

        users.users = lib.listToAttrs (map (s: {
          name = s.owner;
          value = {
            isSystemUser = true;
            group = s.owner;
            home = "/var/empty";
          };
        }) cfg.shares) // {
          root.openssh.authorizedKeys.keys = [
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbmansQ84WUYb3frRU8CKPrZb6DdrfnHavtebK6JF5OQdK3C9nK6Xzoz6YKN4zISv7Vx+o7IReJNwjwV6JrUuOrcavBjTvMCgjotdnlYsk9gpuQjDd0MqHD6WdvuDSWxceKbCIP+6AGrVHKJRycFuLkF49f0fnDDy61+w0NWE3t/U1i2yiWOF+SlwvCxlvMYPFYkMWYarmi2Z3MXV1JCIEGwuv7nTQs/o1EEIk9G/YcjhiRMBRvYp6JaTJIXlpVeGpDp9K79VFWCSm6LdQENSWGwrfBeipdq9qRYHulbzTjWtF3LCcYQUm0Z8ZIIhnaqcqIHgFnYMSB79m/XhvKK3T"
          ];
        };

        services.samba = {
          enable = true;
          settings = {
            global = {
              "server string" = "microatx";
              security = "user";
              "map to guest" = "Bad User";
            };
          } // lib.listToAttrs (map (s: {
            name = s.name;
            value = {
              path = "/srv/${s.name}";
              browseable = "yes";
              "read only" = "no";
              "guest ok" = "yes";
              "force user" = s.owner;
              "force group" = s.owner;
              "create mask" = "0664";
              "directory mask" = "0775";
            };
          }) cfg.shares);
        };

        networking = {
          hostName = "smb";
          firewall.enable = false;
        };

        systemd.network = {
          enable = true;
          networks."20-eth" = {
            matchConfig.Type = "ether";
            addresses = [{ Address = cfg.address; }];
            routes = [{ Gateway = cfg.gateway; }];
          };
        };

        services.openssh.enable = true;

        system.stateVersion = "25.05";
      };
    };
  };
}
