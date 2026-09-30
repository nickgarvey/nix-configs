# home-manager wiring for the ngarvey user, integrated as a NixOS module so it
# activates as part of nixos-rebuild (no standalone `home-manager switch`).
# Imported by modules/desktop/common-workstation.nix, so it is active on every
# workstation. All home-manager config lives here; desktop-environment-specific
# blocks are gated on the relevant NixOS option (e.g. programs.niri.enable) so a
# host that does not run niri gets no niri config.
#
# Convention: home-manager manages config files ONLY (via xdg.configFile, sourced
# verbatim from configs/); the programs themselves are installed system-wide via
# environment.systemPackages, not by home-manager.
{ config, lib, inputs, ... }:

{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit inputs; };
  # Rename pre-existing unmanaged dotfiles (e.g. ~/.config/niri/config.kdl)
  # instead of aborting activation when HM first takes them over.
  home-manager.backupFileExtension = "hmbak";

  home-manager.users.ngarvey = { pkgs, lib, ... }: lib.mkMerge [
    {
      home.stateVersion = "25.11";

      xdg.configFile."nvim/init.lua".source = ../../configs/nvim/init.lua;
      xdg.configFile."ghostty/config".source = ../../configs/ghostty/config;
    }

    # niri-specific home config, only on hosts that run niri (talos, dovahkiin).
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

      # Waybar status bar config. The package itself is installed via
      # environment.systemPackages in modules/desktop/niri.nix and launched by
      # spawn-at-startup in configs/niri.kdl; home-manager only owns the config
      # files here. Hosts without a battery get the file verbatim; hosts that set
      # homelab.niri.hasBattery get a battery module injected before the tray.
      # NOTE: configs/waybar/config.jsonc is strict JSON (no comments / trailing
      # commas) so builtins.fromJSON parses it; keep it that way or revisit here.
      xdg.configFile."waybar/config.jsonc".source =
        if config.homelab.niri.hasBattery then
          let
            base = builtins.fromJSON (builtins.readFile ../../configs/waybar/config.jsonc);
            withBattery = base // {
              modules-right =
                (lib.lists.remove "tray" base.modules-right) ++ [ "battery" "tray" ];
              battery = {
                states = { warning = 20; critical = 10; };
                format = "BAT {capacity}%";
                format-charging = "CHG {capacity}%";
                format-plugged = "AC {capacity}%";
                tooltip-format = "{timeTo}  ({power}W)";
                interval = 30;
              };
            };
          in pkgs.writeText "waybar-config.jsonc" (builtins.toJSON withBattery)
        else ../../configs/waybar/config.jsonc;
      xdg.configFile."waybar/style.css".source = ../../configs/waybar/style.css;

      # Waybar's pulseaudio module has known leak-on-reconnect bugs (e.g.
      # Alexays/Waybar#2619, #3981) that let it balloon to multi-GB before it
      # eventually segfaults, rather than failing fast. Cap its memory so a
      # runaway leak gets OOM-killed (and restarted by the unit's own
      # Restart=on-failure) well before it grows that large. 300M is generous
      # headroom over its normal ~15-20M footprint.
      xdg.configFile."systemd/user/waybar.service.d/override.conf".text = ''
        [Service]
        MemoryHigh=200M
        MemoryMax=300M
      '';

      # Waybar only reads its config at startup. After a deploy relinks the
      # config, restart the bar, but only when the config or style changed and
      # only if the unit is running (try-restart does nothing otherwise). Restart
      # rather than SIGUSR2 reload, which has a history of crashes in waybar.
      # XDG_RUNTIME_DIR is set explicitly because activation runs from the
      # home-manager-ngarvey system service, and `|| true` keeps a failed
      # restart from failing activation (and tripping the deploy watchdog).
      home.activation.restartWaybar = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        if [ -z "''${oldGenPath:-}" ] || \
           ! ${pkgs.diffutils}/bin/cmp -s "$oldGenPath/home-files/.config/waybar/config.jsonc" "$newGenPath/home-files/.config/waybar/config.jsonc" || \
           ! ${pkgs.diffutils}/bin/cmp -s "$oldGenPath/home-files/.config/waybar/style.css" "$newGenPath/home-files/.config/waybar/style.css"; then
          run env XDG_RUNTIME_DIR=/run/user/$(id -u) \
            ${pkgs.systemd}/bin/systemctl --user try-restart waybar.service || true
        fi
      '';

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
