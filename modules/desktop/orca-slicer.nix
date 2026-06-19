{ config, lib, pkgs, ... }:

{
  # See UPSTREAMABLE_FIXES.md: orca-slicer's wrapper sets GST_PLUGIN_SYSTEM_PATH_1_0
  # but not GST_PLUGIN_SCANNER, causing playbin discovery to fail and segfaulting
  # wxMediaCtrl2 when opening the Monitor (printer camera) tab.
  #
  # Also: nixpkgs builds glew with the EGL backend (enableEGL defaults to true on
  # Linux), but orca's wxGLCanvas uses a GLX context. GLEW-EGL can't query the GL
  # version from a GLX context -> "Unable to init glew library, Error: Missing GL
  # version", so the 3D build-plate (grid) never renders and the app crashes.
  # Rebuild glew without EGL. Mirrors nixpkgs PR #531346.
  environment.systemPackages = with pkgs; [
    ((orca-slicer.override {
      glew = glew.override { enableEGL = false; };
    }).overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ../../patches/orca-slicer-null-checks.patch ];
      preFixup = (old.preFixup or "") + ''
        gappsWrapperArgs+=(
          --set GST_PLUGIN_SCANNER "${gst_all_1.gstreamer}/libexec/gstreamer-1.0/gst-plugin-scanner"
        )
      '';
    }))
  ];
}
