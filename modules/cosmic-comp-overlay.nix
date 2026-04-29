{ ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      cosmic-comp = super.cosmic-comp.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          ../patches/cosmic-comp-reduce-tiling-latency.patch
        ];

        # Patch the vendored smithay crate for cosmic-comp #2191 (stale DRM
        # property blob on resume). cargoSetupHook unpacks vendored crates
        # before preBuild runs; locate smithay by its atomic.rs path so we
        # don't depend on whether cargo names the dir `smithay` (git source)
        # or `smithay-X.Y.Z` (crates.io).
        preBuild = (old.preBuild or "") + ''
          atomic=$(find "$NIX_BUILD_TOP" -maxdepth 8 -type f \
            -path '*/src/backend/drm/surface/atomic.rs' 2>/dev/null | head -1)
          [ -n "$atomic" ] || { echo "vendored smithay not found" >&2; exit 1; }
          smithay_dir=''${atomic%/src/backend/drm/surface/atomic.rs}
          echo "patching smithay at $smithay_dir"
          patch -p1 -d "$smithay_dir" \
            < ${../patches/smithay-pending-blob-on-reset.patch}
          # Empty files map => cargo skips per-file checksum verification.
          echo '{"package":null,"files":{}}' \
            > "$smithay_dir/.cargo-checksum.json"
        '';
      });
    })
  ];
}
