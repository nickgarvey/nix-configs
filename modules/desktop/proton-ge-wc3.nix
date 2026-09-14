# Adds the GE-Proton11-5-WC3 Steam compatibility tool, whose patched crypt32 lets Warcraft III: Reforged 3.0 log in.
{ config, lib, pkgs, inputs, ... }:

let
  # The patched tool is temporary until a GE-Proton release carries the crypt32
  # fix (GloriousEggroll/proton-ge-custom PR #765), so it expires rather than
  # rots: the check trips on the first rebuild whose flake or nixpkgs commit
  # lands after the deadline.
  deadline = 1796083200; # 2026-12-01T00:00:00Z
  flakeTime = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;
in
{
  assertions = [{
    assertion = flakeTime < deadline;
    message = ''
      modules/desktop/proton-ge-wc3.nix expired on 2026-12-01. If nixpkgs'
      proton-ge-bin is a GE-Proton release with the crypt32
      CERT_CHAIN_ENGINE_CONFIG fix (PR #765), delete this module and
      pkgs/proton-ge-wc3, and switch the Battle.net shortcut back to GE-Proton.
      Otherwise push the deadline out deliberately.
    '';
  }];

  programs.steam.extraCompatPackages = [
    (pkgs.callPackage ../../pkgs/proton-ge-wc3 { })
  ];
}
