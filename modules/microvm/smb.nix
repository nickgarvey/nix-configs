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

    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IPv6 address with prefix length for the SMB VM (e.g. \"2001:470:482f::14/64\").";
    };

    ipv6Gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IPv6 default gateway for the SMB VM.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      description = "MAC address for the VM's network interface.";
    };

    shares = lib.mkOption {
      type = lib.types.listOf shareType;
      description = "List of SMB shares to expose.";
    };

    credentialsSopsFile = lib.mkOption {
      type = lib.types.path;
      default = ../../secrets/smb-credentials.yaml;
      description = "SOPS file holding smb_password (rw account) and smb_ro_password (ro account).";
    };

    rwUser = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Read-write Samba account (must be a share owner). Password from smb_password.";
    };

    roUser = lib.mkOption {
      type = lib.types.str;
      default = "media-ro";
      description = "Read-only Samba account. Password from smb_ro_password.";
    };
  };

  config = {
    # Render the VM's account credentials on the host (lydia) and expose only
    # this one file to the guest over virtiofs (see the smb-accounts share).
    sops.secrets.smb-rw-password = {
      sopsFile = cfg.credentialsSopsFile;
      key = "smb_password";
    };
    sops.secrets.smb-ro-password = {
      sopsFile = cfg.credentialsSopsFile;
      key = "smb_ro_password";
    };
    sops.templates."smb-vm-accounts" = {
      content = ''
        ${cfg.rwUser}:${config.sops.placeholder.smb-rw-password}
        ${cfg.roUser}:${config.sops.placeholder.smb-ro-password}
      '';
      # On a password change, re-stage the host file and reboot the guest so its
      # (boot-time, oneshot) provisioner reruns. Ordering: stage is transitively
      # before microvm@smb (via virtiofsd), so both restart in the right order.
      restartUnits = [ "smb-vm-accounts-stage.service" "microvm@smb.service" ];
    };

    # sops renders templates as real files under /run/secrets/rendered, which
    # also holds garage/frigate secrets. Copy just this one into a dedicated dir
    # as a real file (a sops custom-path is a symlink the guest can't resolve)
    # so it can be virtiofs-shared into the SMB VM in isolation.
    systemd.services.smb-vm-accounts-stage = {
      description = "Stage SMB VM account credentials for virtiofs";
      before = [ "microvm-virtiofsd@smb.service" ];
      requiredBy = [ "microvm-virtiofsd@smb.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0700 /run/smb-vm-secrets
        install -m 0400 ${config.sops.templates."smb-vm-accounts".path} /run/smb-vm-secrets/accounts
      '';
    };

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

        # microvm.nix bind-mounts /nix/store from /nix/.ro-store without an
        # fsType; current nixpkgs requires one on every fileSystems entry.
        fileSystems."/nix/store".fsType = lib.mkDefault "none";

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
          }) cfg.shares
          ++ [{
            # Host-rendered "user:password" lines consumed by smb-provision-accounts.
            source = "/run/smb-vm-secrets";
            mountPoint = "/run/smb-vm-secrets";
            tag = "smb-accounts";
            proto = "virtiofs";
          }];
        };

        users.groups = lib.listToAttrs (map (s: {
          name = s.owner;
          value = {};
        }) cfg.shares) // {
          "${cfg.roUser}" = {};
        };

        users.users = lib.listToAttrs (map (s: {
          name = s.owner;
          value = {
            isSystemUser = true;
            group = s.owner;
            home = "/var/empty";
          };
        }) cfg.shares) // {
          # Read-only account: authenticates only; share's force-user does the I/O.
          "${cfg.roUser}" = {
            isSystemUser = true;
            group = cfg.roUser;
            home = "/var/empty";
          };
          root.openssh.authorizedKeys.keys = [
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbmansQ84WUYb3frRU8CKPrZb6DdrfnHavtebK6JF5OQdK3C9nK6Xzoz6YKN4zISv7Vx+o7IReJNwjwV6JrUuOrcavBjTvMCgjotdnlYsk9gpuQjDd0MqHD6WdvuDSWxceKbCIP+6AGrVHKJRycFuLkF49f0fnDDy61+w0NWE3t/U1i2yiWOF+SlwvCxlvMYPFYkMWYarmi2Z3MXV1JCIEGwuv7nTQs/o1EEIk9G/YcjhiRMBRvYp6JaTJIXlpVeGpDp9K79VFWCSm6LdQENSWGwrfBeipdq9qRYHulbzTjWtF3LCcYQUm0Z8ZIIhnaqcqIHgFnYMSB79m/XhvKK3T"
          ];
        };

        services.samba = {
          enable = true;
          # No NetBIOS: clients connect directly via DNS/IP on 445.
          nmbd.enable = false;
          settings = {
            global = {
              "server string" = "lydia";
              security = "user";
              "map to guest" = "Never";
              "server min protocol" = "SMB3_00";
              "smb encrypt" = "required";
            };
          } // lib.listToAttrs (map (s: {
            name = s.name;
            value = {
              path = "/srv/${s.name}";
              browseable = "yes";
              # Authenticated access only: rw account via write list, ro otherwise.
              "valid users" = "${cfg.rwUser} ${cfg.roUser}";
              "read only" = "yes";
              "write list" = cfg.rwUser;
              "force user" = s.owner;
              "force group" = s.owner;
              "create mask" = "0664";
              "directory mask" = "0775";
            };
          }) cfg.shares);
        };

        # Provision the rw/ro Samba accounts from the host-rendered credentials
        # file (mounted read-only via the smb-accounts virtiofs share). Idempotent:
        # adds the passdb entry if missing, otherwise just syncs the password.
        systemd.services.smb-provision-accounts = {
          description = "Provision Samba accounts from host-rendered credentials";
          wantedBy = [ "multi-user.target" ];
          before = [ "samba-smbd.service" ];
          unitConfig.RequiresMountsFor = "/run/smb-vm-secrets";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ config.services.samba.package ];
          script = ''
            set -eu
            while IFS=: read -r user pass; do
              [ -z "$user" ] && continue
              if pdbedit -L | grep -q "^$user:"; then
                printf '%s\n%s\n' "$pass" "$pass" | smbpasswd -s "$user"
              else
                printf '%s\n%s\n' "$pass" "$pass" | smbpasswd -s -a "$user"
              fi
            done < /run/smb-vm-secrets/accounts
          '';
        };

        networking = {
          hostName = "smb";
          firewall = {
            enable = true;
            # 445: SMB. 22: management SSH (key-only) — the VM is stateless, so
            # SSH is the only way to inspect it (smbstatus, provisioner logs).
            allowedTCPPorts = [ 445 22 ];
          };
        };

        systemd.network = {
          enable = true;
          networks."20-eth" = {
            matchConfig.Type = "ether";
            addresses = [{ Address = cfg.address; }]
              ++ lib.optional (cfg.ipv6Address != null) { Address = cfg.ipv6Address; };
            routes = [{ Gateway = cfg.gateway; }]
              ++ lib.optional (cfg.ipv6Gateway != null) { Gateway = cfg.ipv6Gateway; };
            networkConfig.IPv6AcceptRA = false;
          };
        };

        services.openssh.enable = true;

        system.stateVersion = "25.05";
      };
    };
  };
}
