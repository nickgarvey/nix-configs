# VLAN 50 "agents" zone for LLM agent VMs: the router is their only L3 hop, and nftables.nix lets them reach the WAN and nothing else.
#
# The VMs (on wabbajack's br-agents, modules/llms/hermes-agents.nix) use static
# addresses and public DNS, so the router serves no DHCP, DNS or RA here and
# its input chain accepts nothing from this interface.
{ ... }:

{
  config = {
    systemd.network.netdevs."20-agents" = {
      netdevConfig = {
        Name = "agents";
        Kind = "vlan";
      };
      vlanConfig.Id = 50;
    };

    systemd.network.networks."10-lan".vlan = [ "agents" ];

    systemd.network.networks."20-agents" = {
      matchConfig.Name = "agents";
      address = [ "10.50.0.1/24" ];
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6SendRA = false;
        ConfigureWithoutCarrier = true;
      };
    };
  };
}
