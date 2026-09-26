# Ceph run directly on the storage nodes (no Rook): a mon, mgr, OSD and RGW on each of joor/zah/frul.
#
# The cluster is bootstrapped by hand (keys, monmap, OSD mkfs; scripts in
# docs/ceph-bootstrap/); this module only configures and runs the daemons.
# A daemon whose keyring is missing does not start (the NixOS module's
# ConditionPathExists). A recovery copy of the admin keyring is in
# secrets/ceph-admin.yaml, which only ngarvey can decrypt.
#
# Public network (clients, mons, RGW) is the LAN; OSD replication and recovery
# use the Thunderbolt mesh (modules/networking/thunderbolt-mesh.nix).
{ config, lib, pkgs, inputs, ... }:

let
  # From the stable release: Ceph major upgrades need an ordered restart
  # (mon, mgr, OSD, RGW), so the version must not move with a routine
  # unstable bump. Unstable's Ceph also does not currently build (its
  # Python env pulls in a package whose tests fail).
  ceph = inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.ceph;

  hostname = config.networking.hostName;
  inherit (import ../networking/lan-hosts.nix) lanHosts;
  lanV6 = name: (lib.findFirst (h: h.hostname == name) null lanHosts).ipv6;

  # OSD id and the whole disk it owns, per node.
  nodes = {
    joor = { osd = "0"; disk = "/dev/disk/by-id/nvme-WD_Blue_SN5100_4TB_25459R801411"; };
    zah = { osd = "1"; disk = "/dev/disk/by-id/nvme-WD_Blue_SN5100_4TB_25459R802281"; };
    frul = { osd = "2"; disk = "/dev/disk/by-id/nvme-WD_Blue_SN5100_4TB_25459R802230"; };
  };
  node = nodes.${hostname} or (throw "ceph.nix: ${hostname} is not a Ceph node");
  monNames = lib.attrNames nodes;

  rgwDomain = "rgw.home.garvey.sh";
  rgwCertDir = "/var/lib/acme/${rgwDomain}";
  # Knot (knot-auth container, 10.28.0.6) through the router's NAT64.
  knotViaNat64 = "[64:ff9b::a1c:6]:53";
in
{
  services.ceph = {
    enable = true;
    global = {
      fsid = "8d324da3-f3ab-40f8-aaa1-71ed33705f75";
      monInitialMembers = lib.concatStringsSep "," monNames;
      monHost = lib.concatMapStringsSep ","
        (n: "[v2:[${lanV6 n}]:3300,v1:[${lanV6 n}]:6789]") monNames;
      # Only the static addresses: matching the whole LAN /64 lets daemons bind a
      # temporary privacy address, which expires.
      publicNetwork = lib.concatMapStringsSep "," (n: "${lanV6 n}/128") monNames;
      clusterNetwork = "fd2f:b7dd:75bc::/48";
      mgrModulePath = "${ceph.lib}/lib/ceph/mgr";
    };
    extraConfig = {
      "ms bind ipv6" = "true";
      "ms bind ipv4" = "false";
      # Read by the mons when a pool is created.
      "osd pool default size" = "3";
      "osd pool default min size" = "2";
    };

    mon = { enable = true; daemons = [ hostname ]; package = ceph; };
    mgr = { enable = true; daemons = [ hostname ]; package = ceph; };
    osd = {
      enable = true;
      daemons = [ node.osd ];
      package = ceph;
      # Replaces the module's defaults (FileStore journal size, fixed PG
      # counts); the PG autoscaler sizes pools instead.
      extraConfig = { };
    };
    rgw = { enable = true; daemons = [ "rgw.${hostname}" ]; package = ceph; };
    client = {
      enable = true;
      # HTTPS on 443 with this node's certificate for the shared name (below);
      # plain HTTP stays on 7480.
      extraConfig."client.rgw.${hostname}"."rgw frontends" =
        "beast endpoint=[::]:7480 ssl_endpoint=[::]:443"
        + " ssl_certificate=${rgwCertDir}/fullchain.pem ssl_private_key=${rgwCertDir}/key.pem";
    };
  };

  # Every node issues its own certificate for rgw.home.garvey.sh (the
  # round-robin S3 name), by DNS-01 against our Knot over RFC2136, as the garage
  # nodes do for theirs (docs/tls.md). The TSIG key may only write TXT at
  # _acme-challenge.rgw (modules/containers/knot-auth.nix). Knot's container is
  # IPv4-only and these nodes are IPv6-only, so lego reaches it through NAT64.
  sops.secrets.rgw-acme-tsig = {
    sopsFile = ../../secrets/rgw-acme.yaml;
    key = "acme_tsig_secret";
  };
  sops.templates."rgw-acme.env".content = ''
    RFC2136_NAMESERVER=${knotViaNat64}
    RFC2136_TSIG_KEY=acme-rgw
    RFC2136_TSIG_ALGORITHM=hmac-sha256.
    RFC2136_TSIG_SECRET=${config.sops.placeholder.rgw-acme-tsig}
  '';
  security.acme = {
    acceptTerms = true;
    defaults.email = "garvey.nick@gmail.com";
    certs.${rgwDomain} = {
      dnsProvider = "rfc2136";
      dnsResolver = knotViaNat64;
      environmentFile = config.sops.templates."rgw-acme.env".path;
      # Same reason as garage.nix: lego's propagation check queries the zone's
      # NS via blocky, whose negative cache outlasts its timeout; Knot is the
      # only authoritative server, so there is nothing to wait for.
      dnsPropagationCheck = false;
      # RGW reads the key as the ceph user.
      group = "ceph";
      # RGW loads its certificate only at start (its reload signal just
      # reopens logs), so restart it on renewal.
      postRun = ''
        ${pkgs.systemd}/bin/systemctl restart ceph-rgw-rgw.${hostname}.service || true
      '';
    };
  };
  systemd.services."ceph-rgw-rgw.${hostname}" = {
    # acme-<name>.service puts a placeholder certificate in place before the
    # first real one is issued, so RGW always has files to load.
    wants = [ "acme-${rgwDomain}.service" ];
    after = [ "acme-${rgwDomain}.service" ];
    serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
  };

  environment.systemPackages = [ ceph ];

  # Mesh interfaces are already trusted; these are for LAN clients and peers.
  # 9283: the mgr prometheus module, scraped by the k3s cluster's Prometheus.
  networking.firewall.allowedTCPPorts = [ 443 3300 6789 9283 ];
  # OSD and mgr messengers (ms_bind_port_min..max), and RGW on 7480.
  networking.firewall.allowedTCPPortRanges = [ { from = 6800; to = 7568; } ];
}
