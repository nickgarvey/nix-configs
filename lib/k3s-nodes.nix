{ nixpkgs, disko, sops-nix, inputs }:

let
  mkK3sNode = name: nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      disko.nixosModules.disko
      sops-nix.nixosModules.sops
      ../hosts/${name}/configuration.nix
      ../hosts/${name}/disk-config.nix
    ];
  };
in
{
  generateK3sNodes = names: nixpkgs.lib.listToAttrs (
    map (n: {
      name = n;
      value = mkK3sNode n;
    }) names
  );
}
