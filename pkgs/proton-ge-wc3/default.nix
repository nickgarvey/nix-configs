# GE-Proton11-5 with crypt32 rebuilt to accept the 88-byte CERT_CHAIN_ENGINE_CONFIG used by Warcraft III: Reforged 3.0.
#
# WC3 3.0's ClientSdk validates Battle.net's certificate chain with the newer
# CERT_CHAIN_ENGINE_CONFIG layout. Proton's Wine 11.0 rejects that size with
# E_INVALIDARG, and the game reports it as "Please check your VPN". Upstream
# Wine fixed it in wine-11.6; this rebuilds crypt32 from the exact Wine tree
# GE-Proton11-5 ships, with those upstream commits applied.
#
# The tool is a full copy of the GE release rather than a symlink overlay: Wine
# locates its DLL directory from realpath(ntdll.so), so symlinks back into
# proton-ge-bin would load the unpatched crypt32.dll.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  fetchpatch,
  pkgsCross,
  autoconf,
  bison,
  flex,
  perl,
  python3,
  proton-ge-bin,
}:

assert lib.assertMsg (proton-ge-bin.version == "GE-Proton11-5") ''
  pkgs/proton-ge-wc3 builds crypt32 from GE-Proton11-5's Wine tree, but
  nixpkgs' proton-ge-bin is now ${proton-ge-bin.version}. If that release
  includes the crypt32 CERT_CHAIN_ENGINE_CONFIG fix, delete this package.
  Otherwise update the Wine rev and wine-staging rev below to that release's
  submodules.
'';

let
  crypt32 = stdenv.mkDerivation {
    pname = "proton-ge-wc3-crypt32";
    version = proton-ge-bin.version;

    # ValveSoftware/wine at GE-Proton11-5's `wine` submodule.
    src = fetchFromGitHub {
      owner = "ValveSoftware";
      repo = "wine";
      rev = "36078f5f947532885a596dabbc7893c048133660";
      hash = "sha256-US/ts2HLhKr+xHMCUWIFlpmQdJ3CDkYeMUB2EAzOblU=";
    };

    patches = [
      # Upstream Wine (wine-11.5/11.6): accept the 88-byte layout.
      (fetchpatch {
        name = "include-update-CERT_CHAIN_ENGINE_CONFIG.patch";
        url = "https://gitlab.winehq.org/wine/wine/-/commit/2012949a0de0b550d221c5514f5632efcd8c3df2.patch";
        hash = "sha256-VYi9N4948xksjI40baCmerE8yvnGeHS2i39dSTGvCKU=";
      })
      (fetchpatch {
        name = "crypt32-trace-CERT_CHAIN_ENGINE_CONFIG.patch";
        url = "https://gitlab.winehq.org/wine/wine/-/commit/02bb0a34ad51a7ac4eda1f50d6ac3b7938487185.patch";
        hash = "sha256-FIH+B92mUUHanYm8KewsOGGHr2qSEpgfblLcNrz2LLo=";
      })
      (fetchpatch {
        name = "crypt32-check-dwExclusiveFlags-size.patch";
        url = "https://gitlab.winehq.org/wine/wine/-/commit/eef8e97dd335beccb23f3b13d4f4ad715f23f359.patch";
        hash = "sha256-fgxmSKnuqLJmU5F1pXMWCg12MRidkwICo/eOu781vwY=";
      })
      (fetchpatch {
        name = "crypt32-accept-config-without-dwExclusiveFlags.patch";
        url = "https://gitlab.winehq.org/wine/wine/-/commit/c7cc9be89613cbe21e1af9ffc7b7e8352feac488.patch";
        hash = "sha256-d42wPdp++vMvSjPavvnkkvvTVTvTANnRKNYtdqY6dQk=";
      })
      # The one wine-staging patchset GE-Proton11-5 applies to crypt32, from its
      # `wine-staging` submodule. Omitting it would drop that fix from the DLL.
      (fetchpatch {
        name = "crypt32-skip-unknown-CMS-certificate-item.patch";
        url = "https://raw.githubusercontent.com/wine-staging/wine-staging/6cc805ea57132eeaf44764e9213823c9b8d0d300/patches/crypt32-CMS_Certificates/0001-crypt32-Skip-unknown-item-when-decoding-a-CMS-certif.patch";
        hash = "sha256-tYEPJgLvXIGbflq0FCDTOIxuaRn5bV6hbwcpzoexjgE=";
      })
    ];

    nativeBuildInputs = [
      autoconf
      bison
      flex
      perl
      python3
      pkgsCross.mingw32.buildPackages.gcc
      pkgsCross.mingwW64.buildPackages.gcc
    ];

    # Valve's tree carries neither a configure script nor the generated Vulkan
    # and syscall headers that makedep scans; generate them the way GE-Proton's
    # build does.
    preConfigure = ''
      patchShebangs tools dlls/winevulkan/make_vulkan
      XDG_CACHE_HOME=$TMPDIR dlls/winevulkan/make_vulkan -x vk.xml -X video.xml
      tools/make_specfiles
      autoreconf -f
    '';

    configureFlags = [
      "--enable-archs=i386,x86_64"
      "--without-x"
      "--without-freetype"
    ];

    enableParallelBuilding = true;

    # Only the PE side of crypt32 changes; GE's crypt32.so is kept as shipped.
    buildPhase = ''
      runHook preBuild
      make -j$NIX_BUILD_CORES \
        dlls/crypt32/x86_64-windows/crypt32.dll \
        dlls/crypt32/i386-windows/crypt32.dll
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 dlls/crypt32/x86_64-windows/crypt32.dll $out/x86_64-windows/crypt32.dll
      install -Dm644 dlls/crypt32/i386-windows/crypt32.dll $out/i386-windows/crypt32.dll
      runHook postInstall
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "proton-ge-wc3";
  version = proton-ge-bin.version;

  outputs = [
    "out"
    "steamcompattool"
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # The release is prebuilt and runs inside Steam's runtime; leave it untouched.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    echo "proton-ge-wc3 should not be installed into environments. Please use programs.steam.extraCompatPackages instead." > $out

    cp -r ${proton-ge-bin.src} $steamcompattool
    chmod u+w $steamcompattool $steamcompattool/compatibilitytool.vdf
    for arch in x86_64 i386; do
      dir=$steamcompattool/files/lib/wine/$arch-windows
      chmod u+w $dir $dir/crypt32.dll
      install -m644 ${crypt32}/$arch-windows/crypt32.dll $dir/crypt32.dll
    done

    # A distinct internal name keeps it alongside the plain GE-Proton entry.
    substituteInPlace $steamcompattool/compatibilitytool.vdf \
      --replace-fail "GE-Proton11-5-x86_64" "GE-Proton11-5-WC3"

    runHook postInstall
  '';

  passthru = { inherit crypt32; };

  meta = {
    description = "GE-Proton11-5 with crypt32 patched for Warcraft III: Reforged 3.0 login";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}
