{ pkgs, helium-browser-pkg }:

let
  # Fix chrome-wrapper -> helium-wrapper (will fail when upstream fixes this)
  # PR for upstream fix:
  # https://github.com/nickgarvey/helium-browser-flake/commit/1b79feb00826098a661b442eaae0b3ebb81d0dc5
  patchedHeliumPkg = helium-browser-pkg.overrideAttrs (oldAttrs: {
    installPhase =
      let
        original = oldAttrs.installPhase or "";
        hasIssue = builtins.match ".*chrome-wrapper.*" original != null;
      in
        if !hasIssue then
          throw "chrome-wrapper fix is no longer needed! Remove override."
        else
          pkgs.lib.replaceStrings [ "chrome-wrapper" ] [ "helium-wrapper" ] original;
  });
in

pkgs.symlinkJoin {
  name = "helium-browser-with-desktop";
  paths = [ patchedHeliumPkg ];

  buildInputs = [ pkgs.makeWrapper ];

  postBuild = ''
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
