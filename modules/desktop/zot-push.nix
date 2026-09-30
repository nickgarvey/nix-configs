# Push access to the oci.garvey.sh registry (zot) for ngarvey, via a standard containers auth.json.
#
# zot allows anonymous pulls but needs credentials to push or delete. The
# credential (secrets/zot-push.yaml) is rendered into a containers-auth.json(5)
# file and linked to ~/.config/containers/auth.json, which skopeo, podman and
# buildah read when there is no login in $XDG_RUNTIME_DIR/containers/auth.json.
# So `skopeo copy docker-archive:result docker://oci.garvey.sh/<repo>:<tag>`
# works with no login step. docker and crane read ~/.docker/config.json instead
# and do not see it.
#
# zot holds only the bcrypt hash (k8s-gitops manifests/zot/secret.yaml); rotate
# both together.
{ config, pkgs, ... }:

let
  authFile = config.sops.templates."zot-push-auth.json".path;
in
{
  sops.secrets.zot-push-auth = {
    sopsFile = ../../secrets/zot-push.yaml;
    key = "auth";
  };

  sops.templates."zot-push-auth.json" = {
    owner = "ngarvey";
    mode = "0400";
    content = builtins.toJSON {
      auths."oci.garvey.sh".auth = config.sops.placeholder.zot-push-auth;
    };
  };

  home-manager.users.ngarvey = hm: {
    xdg.configFile."containers/auth.json".source =
      hm.config.lib.file.mkOutOfStoreSymlink authFile;
  };

  environment.systemPackages = [ pkgs.skopeo ];
}
