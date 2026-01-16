{ pkgs, helium-browser-pkg }:

pkgs.symlinkJoin {
  name = "helium-browser-with-desktop";
  paths = [ helium-browser-pkg ];
  
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
