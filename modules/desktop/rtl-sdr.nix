# RTL-SDR USB dongle support: udev rules, plugdev access, and DVB driver blacklist.

{ ... }:

{
  # Installs rtl-sdr-blog, adds its udev rules (0660, group plugdev), creates the
  # plugdev group, and blacklists the DVB-T kernel drivers that would otherwise
  # claim the dongle and make librtlsdr fail with usb_claim_interface -6.
  hardware.rtl-sdr.enable = true;

  # hardware.rtl-sdr creates plugdev but puts nobody in it.
  users.users.ngarvey.extraGroups = [ "plugdev" ];
}
