{ ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      upower = super.upower.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          ../../patches/upower-filter-spurious-zero.patch
        ];
        doCheck = false;
      });
    })
  ];
}
