{ ... }:

# Honor RA route-information options (RFC 4191) for prefixes up to /64.
#
# The router advertises 2001:470:482f::/48 as route-info via RA so LAN
# hosts and router-side nspawn containers learn intra-site routes
# (LB pool :2::/112, pod CIDRs :100::/56, per-host /64 delegations) with
# no static configuration. See modules/router/lan-ipv6.nix and
# modules/networking/lan-hosts.nix for the subnet plan.
#
# systemd-networkd parses RA in userspace and honors route-info
# regardless of this sysctl. Kernel-managed interfaces (notably nspawn
# containers without networkd) silently drop the option unless
# accept_ra_rt_info_max_plen is raised from its default of 0.
#
# /64 ceiling: covers the current /48 advertisement and any future
# per-/64 route-info advertisement. Nothing in the prefix plan is more
# specific than /64 at the RA layer.

{
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.accept_ra_rt_info_max_plen" = 64;
    "net.ipv6.conf.default.accept_ra_rt_info_max_plen" = 64;
  };
}
