{ config, pkgs, ... }:
{
  hardware.keyboard.zsa.enable = true;

  environment.systemPackages = with pkgs; [
    qmk
    dfu-util       # Flasher for STM32 according
    git
  ];
}