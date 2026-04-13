{ nixpkgs, disko, sops-nix, inputs }:

let
  mkK3sNode = nodeNumber: nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      disko.nixosModules.disko
      sops-nix.nixosModules.sops
      ../hosts/k3s-node-${toString nodeNumber}/configuration.nix
      ../hosts/k3s-node-${toString nodeNumber}/disk-config.nix
    ];
  };
in
{
  generateK3sNodes = nodeNumbers: nixpkgs.lib.listToAttrs (
    map (n: {
      name = "k3s-node-${toString n}";
      value = mkK3sNode n;
    }) nodeNumbers
  );
}
