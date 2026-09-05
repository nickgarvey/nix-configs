{ pkgs, ... }:

{
  # Printing
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      gutenprint
      # Qt5 GUI tools (hp-toolbox) are off: they need PyQt5, which does not
      # build against the current python3. CUPS drivers are unaffected.
      (hplip.override { withQt5 = false; })
    ];
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      workstation = true;
    };
  };
  services.ipp-usb.enable = true;

  users.users.ngarvey.extraGroups = [ "lp" "lpadmin" ];
}
