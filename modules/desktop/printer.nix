{ pkgs, ... }:

{
  # Printing
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      gutenprint
      hplip
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
