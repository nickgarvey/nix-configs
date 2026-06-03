{ ... }:
{
  # Allow the Keychron Launcher / VIA web UI (WebHID) to configure Keychron
  # keyboards without root. The web UI runs as the logged-in user, so it needs
  # access to the keyboard's /dev/hidraw* node, which is root-only by default.
  #   3434 - Keychron vendor ID (e.g. Q11 = 3434:01e0)
  # GROUP="users" + MODE="0660" grants access deterministically the moment the
  # node is created (the local user is in "users"). TAG+="uaccess" additionally
  # grants the active-seat user via logind, but logind is unreliable about
  # applying the ACL on hidraw hotplug events, so we don't depend on it alone.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", ATTRS{idVendor}=="3434", MODE="0660", GROUP="users", TAG+="uaccess"
  '';
}
