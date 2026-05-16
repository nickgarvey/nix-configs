{ buildGoModule, fetchFromGitHub, lib }:

buildGoModule rec {
  pname = "storj-gateway-st";
  version = "1.11.0";

  src = fetchFromGitHub {
    owner = "storj";
    repo = "gateway-st";
    rev = "v${version}";
    hash = "sha256-XTcwDktYHuebhrZxAyM9VRwlyYiCSXNRl7HSG0wZVYY=";
  };

  # buildGoModule will compute the vendor hash on first build and print
  # the expected value when this placeholder mismatches. Replace then.
  vendorHash = "sha256-HPLpM4p0pJOAorYLjldggVxzXG1635tqHU6SUdWmrIE=";

  # Single main package at the repo root produces the `gateway` binary.
  subPackages = [ "." ];

  postInstall = ''
    # Match the upstream Docker image's binary name.
    mv $out/bin/gateway-st $out/bin/gateway 2>/dev/null || true
  '';

  doCheck = false;

  meta = with lib; {
    description = "Self-hosted S3-compatible gateway for the Storj DCS network";
    homepage = "https://github.com/storj/gateway-st";
    license = licenses.asl20;
    mainProgram = "gateway";
  };
}
