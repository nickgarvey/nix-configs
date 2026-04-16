{ config, lib, ... }:

# Sops wiring for icmpv6-archive. Imported separately so hosts without
# sops-nix can still use modules/icmpv6-archive/default.nix by supplying
# their own credentials file.
#
# Assumes the host's sops-nix is already configured (sops.age.keyFile etc.,
# as done in modules/nixos-common.nix / modules/k3s-common.nix).

{
  sops.secrets.icmpv6-archive-s3-access-key = {
    sopsFile = ../../secrets/icmpv6-archive.yaml;
    key = "s3_access_key";
  };
  sops.secrets.icmpv6-archive-s3-secret-key = {
    sopsFile = ../../secrets/icmpv6-archive.yaml;
    key = "s3_secret_key";
  };

  sops.templates."icmpv6-archive-s3.env".content = ''
    AWS_ACCESS_KEY_ID=${config.sops.placeholder.icmpv6-archive-s3-access-key}
    AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.icmpv6-archive-s3-secret-key}
  '';

  services.icmpv6-archive.s3.credentialsFile =
    config.sops.templates."icmpv6-archive-s3.env".path;
}
