{ ... }:
{
  # Allow unprivileged access to Espressif ESP-Prog-2 USB JTAG adapter:
  #   303a:1002 - ESP-Prog-2
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1002", MODE="0666"
  '';
}
