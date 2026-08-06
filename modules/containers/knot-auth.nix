{ config, lib, pkgs, inputs, ... }:

# Authoritative DNS for home.garvey.sh (Knot), the zone we serve ourselves.
#
# Blocky owns :53 on the router host (all interfaces), so this can't live on the
# host directly -- it runs in a dedicated nspawn container with its own LAN IPv4,
# mirroring public-dns-proxy. LAN queries arrive via knot-resolver's forward stub
# (modules/router/knot-resolver.nix), which blocky uses as its upstream; public
# queries arrive via the router's WAN :53 DNAT into public-dns-proxy's dnsdist.
#
# Knot is authoritative-only: it answers for this zone and returns a referral for
# the k8s.home.garvey.sh subzone. It never recurses and never forwards.

let
  domain = "home.garvey.sh";

  # Zone serial must increase on every content change. The flake's lastModified
  # is monotonic across commits; max() with nixpkgs guards against a dirty tree
  # reporting 0 (same pattern as modules/desktop/mic-mute.nix).
  serial = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;

  zoneText = import ../networking/zone.nix { inherit lib domain serial; };
  zoneFile = pkgs.writeText "${domain}.zone" zoneText;
in
{
  imports = [ ./common.nix ];

  nspawn.network.knot-auth = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.6/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
    # No ipv4DefaultRoute and no IPv6: Knot only ever answers queries from the
    # LAN (blocky) and, later, from dnsdist. It never initiates traffic, so it
    # needs neither a default route nor reachability outside br-lan.
  };

  containers.knot-auth = {
    # The zone file lives in the Nix store, which nspawn bind-mounts read-only
    # into the container -- so a config change is a store path change.
    config = { config, pkgs, ... }: {
      services.knot = {
        enable = true;
        settings = {
          server.listen = [ "0.0.0.0@53" "::@53" ];

          template.default = {
            # Input-only zone file: it lives in the Nix store and must never be
            # rewritten. -1 disables flushing the journal back to it.
            zonefile-sync = -1;
            # "whole" reloads the store file as-is, which is right while the zone
            # is fully static. Switch to "difference" (plus journal-content =
            # "changes") when TSIG/DDNS lands for ACME challenges, so dynamically
            # added records survive a reload instead of being wiped by the file.
            zonefile-load = "whole";
          };

          # Absolute path, so Knot's `storage` stays at its default /var/lib/knot
          # (StateDirectory, writable) for the journal and any future kasp-db.
          # Pointing `storage` at the store instead would make those unwritable.
          zone.${domain}.file = toString zoneFile;

          log.syslog.any = "info";
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
