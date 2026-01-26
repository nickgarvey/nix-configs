{
  stdenvNoCC,
  lib,
  fetchurl,
  libarchive, # provides bsdtar
}:
stdenvNoCC.mkDerivation {
  pname = "xone-dongle-firmware";
  version = "0-unstable-2025-01-25";

  srcs = [
    # PID 02e6 - Old dongle
    (fetchurl {
      name = "xone_dongle_02e6.cab";
      url = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2017/03/2ea9591b-f751-442c-80ce-8f4692cdc67b_6b555a3a288153cf04aec6e03cba360afe2fce34.cab";
      sha256 = "0cpgb0i4dnfm0h3kc7xc0lhc4d2cypkpz22wdpqw9dqhvkl756nq";
    })
    # PID 02fe - New dongle
    (fetchurl {
      name = "xone_dongle_02fe.cab";
      url = "https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2017/07/1cd6a87c-623f-4407-a52d-c31be49e925c_e19f60808bdcbfbd3c3df6be3e71ffc52e43261e.cab";
      sha256 = "013g1zngxffavqrk5jy934q3bdhsv6z05ilfixdn8dj0zy26lwv5";
    })
    # PID 02f9 - China variant
    (fetchurl {
      name = "xone_dongle_02f9.cab";
      url = "https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2017/06/1dbd7cb4-53bc-4857-a5b0-5955c8acaf71_9081931e7d664429a93ffda0db41b7545b7ac257.cab";
      sha256 = "1q1fmng898aqp0nzdq4vcm5qzwfhwz00k0gx0xs3h3a6czxr3pch";
    })
    # PID 091e - Brazil variant
    (fetchurl {
      name = "xone_dongle_091e.cab";
      url = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2017/08/aeff215c-3bc4-4d36-a3ea-e14bfa8fa9d2_e58550c4f74a27e51e5cb6868b10ff633fa77164.cab";
      sha256 = "1wnqrh130hxyi0ddjq9d0ac30rwplh674d47g9lwqn0yabcvm3ss";
    })
  ];

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ libarchive ];

  unpackPhase = ''
    sources=($srcs)

    # Extract PID 02e6
    bsdtar -xf ''${sources[0]} FW_ACC_00U.bin
    mv FW_ACC_00U.bin xone_dongle_02e6.bin

    # Extract PID 02fe
    bsdtar -xf ''${sources[1]} FW_ACC_00U.bin
    mv FW_ACC_00U.bin xone_dongle_02fe.bin

    # Extract PID 02f9
    bsdtar -xf ''${sources[2]} FW_ACC_CL.bin
    mv FW_ACC_CL.bin xone_dongle_02f9.bin

    # Extract PID 091e
    bsdtar -xf ''${sources[3]} FW_ACC_BR.bin
    mv FW_ACC_BR.bin xone_dongle_091e.bin
  '';

  installPhase = ''
    install -Dm644 xone_dongle_02e6.bin $out/lib/firmware/xone_dongle_02e6.bin
    install -Dm644 xone_dongle_02fe.bin $out/lib/firmware/xone_dongle_02fe.bin
    install -Dm644 xone_dongle_02f9.bin $out/lib/firmware/xone_dongle_02f9.bin
    install -Dm644 xone_dongle_091e.bin $out/lib/firmware/xone_dongle_091e.bin
  '';

  meta = {
    description = "Xbox One wireless dongle firmware for xone driver";
    homepage = "https://github.com/dlundqvist/xone";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
}
