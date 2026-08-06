{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ../networking/lan-hosts.nix) lanHosts;
  dns = import ../networking/dns.nix { inherit lib; };

  # lanHosts uses single-string ipv4/ipv6 (one physical host = one IP per family).
  hostIpStr = h:
    if h.ipv4 != null && h.ipv6 != null then "${h.ipv4},${h.ipv6}"
    else if h.ipv6 != null then h.ipv6
    else h.ipv4;

  # dns.records uses list-valued v4/v6, joined for blocky's comma-separated syntax.
  recordIpStr = r: lib.concatStringsSep "," (r.v4 ++ r.v6);

  entries =
    (map (h: { name = h.hostname; value = hostIpStr h; }) lanHosts) ++
    (lib.mapAttrsToList (n: r: { name = n; value = recordIpStr r; }) dns.records);

  dnsMapping = builtins.listToAttrs (
    entries ++
    (map (e: e // { name = "${e.name}.${cfg.domain}"; }) entries)
  );

  cnameLines = lib.mapAttrsToList
    (name: target: "${name} 300 IN CNAME ${target}") dns.cnames;

  zoneText = lib.concatStringsSep "\n"
    ([ "$ORIGIN ${cfg.domain}." ] ++ cnameLines);
in
{
  config = {
    users.groups.blocky-secrets = { };
    sops.secrets.domains = {
      sopsFile = ../../secrets/dragonsreach.yaml;
      group = "blocky-secrets";
      mode = "0440";
    };

    systemd.services.blocky = {
      # services.blocky runs under DynamicUser, so the only way to reach the
      # secret is a supplementary group.
      serviceConfig.SupplementaryGroups = [ "blocky-secrets" ];

      # Blocky downloads its denylists over HTTPS and resolves those URLs
      # through the system resolver -- which is blocky itself, forwarding to
      # kresd. Without this ordering blocky starts first, the download fails
      # with "Temporary failure in name resolution", and the ads group stays
      # EMPTY until the next refresh: no blocking for hours, silently. Wants
      # (not Requires) so a kresd failure degrades resolution rather than
      # taking blocky down with it.
      after = [ "knot-resolver.service" ];
      wants = [ "knot-resolver.service" ];
    };

    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 53;
          http = 4000;
        };

        # Local knot-resolver (modules/router/knot-resolver.nix), which recurses
        # from the root instead of forwarding to a public DoH provider. Blocky
        # is a forwarder and can't chase CNAMEs from an upstream; kresd can, so
        # resolution lives there and blocky stays a policy layer.
        #
        # Same host as blocky, so this adds no new failure domain.
        upstreams.groups.default = [ "tcp+udp:127.0.0.1:5353" ];

        # Needed for the denylist DOWNLOADS, not for the upstream above (that
        # one is a literal address). Without it blocky resolves list URLs via
        # the OS resolver -- which is blocky itself on 127.0.0.1:53, not yet
        # bound while lists load -- so every download fails with "Temporary
        # failure in name resolution" and the ads group starts empty. Point it
        # straight at kresd to break the self-dependency.
        bootstrapDns = [ "tcp+udp:127.0.0.1:5353" ];

        blocking = {
          denylists = {
            ads = [
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
            ];
            local = [ config.sops.secrets.domains.path ];
          };
          clientGroupsBlock = {
            default = [ "ads" "local" ];
          };

          # Second layer of defence for the startup race the systemd ordering
          # above fixes: if the resolver is still coming up (or GitHub is
          # briefly unreachable), retry with a real cooldown instead of giving
          # up in ~1s and running with an empty denylist until refreshPeriod.
          loading = {
            downloads = {
              attempts = 5;
              cooldown = "10s";
              timeout = "60s";
            };
            # Serve DNS immediately rather than blocking startup on the
            # download -- the retries above cover the transient case.
            strategy = "fast";
          };
        };

        conditional = {
          # The *.garvey.sh zones are deliberately NOT here -- they are kresd
          # forward stubs (modules/router/knot-resolver.nix). A mapping here
          # would short-circuit straight to the authoritative server, and blocky
          # would hand back Knot's CNAME-plus-referral without chasing it,
          # breaking clients that don't re-query (musl/Alpine).
          #
          # home.arpa stays: k8s_gateway emits only A/AAAA and never a CNAME, so
          # it can't produce a partial answer, and home.arpa is an RFC 8375
          # special-use name a recursive resolver may decline to handle. Retired
          # at the cutover.
          mapping = {
            "k8s.home.arpa" = "[2001:470:482f:2::53]";
          };
        };

        customDNS = {
          # garveyShOverrides keys are already fully-qualified (oci.garvey.sh),
          # so merge them in directly without the home.arpa FQDN suffix.
          mapping = dnsMapping // dns.garveyShOverrides;
          zone = zoneText;
        };

        dns64 = {
          enable = true;
          prefixes = [ "64:ff9b::/96" ];
        };

        queryLog = {
          type = "none";
        };
      };
    };

    # Ensure the router itself uses blocky for DNS
    networking.nameservers = [ "127.0.0.1" ];

    # Disable systemd-resolved since blocky handles DNS
    services.resolved.enable = false;
  };
}
