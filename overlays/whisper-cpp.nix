final: prev: {

  whisper-cpp = prev.whisper-cpp.overrideAttrs (oldAttrs: rec {
    pname = "whisper-cpp";
    version = "1.7.6";

    # Override the source to point to the new version's tag and hash.
    src = prev.fetchFromGitHub {
      owner = "ggerganov";
      repo = "whisper.cpp";
      rev = "v${version}"; # Uses the overridden version "1.7.6"
      # The SHA256 hash for the source of v1.7.6
      hash = "sha256-dppBhiCS4C3ELw/Ckx5W0KOMUvOHUiisdZvkS7gkxj4=";
    };

    # Note: This overlay does not add support for new build options
    # introduced after the version currently in nixpkgs (e.g., Vulkan).
    # It uses the existing build configuration.
  });

}

