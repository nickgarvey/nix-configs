{ ... }:
{
  # Allow unprivileged access to Raspberry Pi Pico USB devices:
  #   2e8a - RP2040/RP2350 in BOOTSEL mode (picotool target)
  #   1209:c0ca - pico-dirtyJtag running firmware
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="c0ca", MODE="0666"
  '';
}
