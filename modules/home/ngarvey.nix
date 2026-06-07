# home-manager wiring for the ngarvey user, integrated as a NixOS module so it
# activates as part of nixos-rebuild (no standalone `home-manager switch`).
# Imported by modules/desktop/common-workstation.nix, so it is active on every
# workstation. All home-manager config lives here; desktop-environment-specific
# blocks are gated on the relevant NixOS option (e.g. programs.niri.enable) so a
# host that does not run niri gets no niri config.
{ config, lib, inputs, ... }:

{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit inputs; };
  # Rename pre-existing unmanaged dotfiles (e.g. ~/.config/niri/config.kdl)
  # instead of aborting activation when HM first takes them over.
  home-manager.backupFileExtension = "hmbak";

  home-manager.users.ngarvey = { pkgs, ... }: lib.mkMerge [
    {
      home.stateVersion = "25.11";
    }

    # niri-specific home config, only on hosts that run niri (e.g. wabbajack).
    (lib.mkIf config.programs.niri.enable {
      # niri compositor config, managed verbatim from the repo. It is run
      # through `niri validate` at build time, so a syntax error fails
      # nixos-rebuild instead of being deployed (a bad config silently drops
      # niri to its built-in default). The validation derivation is a
      # dependency of the activated system, so the check cannot be skipped on
      # deploy.
      xdg.configFile."niri/config.kdl".source =
        let niriOutputs = pkgs.writeText "niri-outputs.kdl" config.homelab.niri.outputs;
        in pkgs.runCommandLocal "niri-config.kdl" { nativeBuildInputs = [ pkgs.niri ]; } ''
          cat ${../../configs/niri.kdl} ${niriOutputs} > "$out"
          niri validate -c "$out"
        '';

      # Waybar status bar config, managed verbatim from the repo. The package
      # itself is installed via environment.systemPackages in
      # modules/desktop/niri.nix and launched by spawn-at-startup in
      # configs/niri.kdl; home-manager only owns the config files here.
      xdg.configFile."waybar/config.jsonc".source = ../../configs/waybar/config.jsonc;
      xdg.configFile."waybar/style.css".source = ../../configs/waybar/style.css;

      # Notification daemon. NOTE: this module only installs+configures mako; it
      # does not create a systemd unit, so mako is launched via spawn-at-startup
      # in configs/niri.kdl.
      services.mako.enable = true;

      # Clipboard history. Creates text+image wl-paste watchers that autostart
      # under graphical-session.target (reached by niri's --session mode).
      services.cliphist.enable = true;
    })
  ];
}
