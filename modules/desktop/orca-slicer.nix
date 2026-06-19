{ config, lib, pkgs, ... }:

{
  # See UPSTREAMABLE_FIXES.md: orca-slicer's wrapper sets GST_PLUGIN_SYSTEM_PATH_1_0
  # but not GST_PLUGIN_SCANNER, causing playbin discovery to fail and segfaulting
  # wxMediaCtrl2 when opening the Monitor (printer camera) tab.
  environment.systemPackages = with pkgs; [
    (orca-slicer.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ../../patches/orca-slicer-null-checks.patch ];
      preFixup = (old.preFixup or "") + ''
        gappsWrapperArgs+=(
          --set GST_PLUGIN_SCANNER "${gst_all_1.gstreamer}/libexec/gstreamer-1.0/gst-plugin-scanner"
        )
      '';
    }))
  ];
}
