{ pkgs, helium-browser-pkg }:

let
  # Helium resolves its install dir via `readlink -f`, so WidevineCdm must sit
  # beside the real binary; the symlinkJoin below cannot place it there.
  helium-with-widevine = helium-browser-pkg.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      ln -s ${pkgs.widevine-cdm}/share/google/chrome/WidevineCdm "$libExecPath/WidevineCdm"
    '';
  });
in
pkgs.symlinkJoin {
  name = "helium-browser-with-desktop";
  paths = [ helium-with-widevine ];

  buildInputs = [ pkgs.makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/helium \
      --add-flags "--password-store=basic" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --ozone-platform-hint=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

    mkdir -p $out/share/applications
    cat > $out/share/applications/helium-browser.desktop << EOF
[Desktop Entry]
Version=1.0
Name=Helium Browser
GenericName=Web Browser
Comment=Browse the World Wide Web
Exec=$out/bin/helium %U
Terminal=false
Type=Application
Icon=chromium
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;video/webm;application/x-xpinstall;
StartupNotify=true
StartupWMClass=helium
EOF
  '';
}
