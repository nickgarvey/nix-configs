{ lib
, stdenv
, fetchurl
, makeWrapper
, jdk21
, bash
, xorg
, fontconfig
, buildFHSEnv
, unzip
}:

let
  pname = "triplea";
  version = "2.7.15097";

  triplea-data = stdenv.mkDerivation {
    inherit pname version;

    src = fetchurl {
      url = "https://github.com/triplea-game/triplea/releases/download/${version}/triplea-game-headed.zip";
      sha256 = "sha256-fAuLF04BshKIbFiD2QVfU5L5CO+Giw9ZzQUzFKZDO40=";
    };

    nativeBuildInputs = [ unzip ];
    sourceRoot = ".";

    installPhase = ''
      mkdir -p $out
      cp -r ./* $out/
      # Needed so triplea does not fail with "Unable to locate root folder"
      touch $out/.triplea-root
    '';
  };

in
buildFHSEnv {
  name = pname;

  targetPkgs = pkgs: with pkgs; [
    jdk21
    bash
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libXtst
    xorg.libXi
    fontconfig
  ];

  runScript = ''
    #!${bash}/bin/bash
    cd ${triplea-data}
    java -jar bin/triplea-game-headed-2.7+15097.jar "$@"
  '';

  meta = with lib; {
    description = "TripleA is a turn-based strategy game and board game engine";
    longDescription = ''
      TripleA is a free online turn-based strategy game and board game engine,
      similar to Axis & Allies or Risk.
    '';
    homepage = "https://triplea-game.org/";
    license = licenses.gpl3Plus;
    maintainers = [ "ngarvey" ];
    platforms = platforms.linux;
    mainProgram = "triplea";
  };
}

