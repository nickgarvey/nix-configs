{ buildGoModule, fetchFromGitHub, lib }:

buildGoModule rec {
  pname = "agent-issue-tracker";
  version = "1.15.0";

  src = fetchFromGitHub {
    owner = "ohnotnow";
    repo = "agent-issue-tracker";
    rev = "v${version}";
    hash = "sha256-ICvDvPtYXq+Q647UbUvN1UhhH7BSaKkkrK/QOn6yFnE=";
  };

  vendorHash = "sha256-+jdz9R40HGu2sS2RCN+Q2qh/8FskscJZz5Jo3NlAxbA=";

  # The `ait` binary; the repo root holds no main package.
  subPackages = [ "cmd/ait" ];

  # Same stamping as upstream's release workflow, so `ait version` reports a
  # real version instead of "dev".
  ldflags = [
    "-X github.com/ohnotnow/agent-issue-tracker/internal/ait.Version=${version}"
  ];

  meta = with lib; {
    description = "Local-first issue tracker for coding agents";
    homepage = "https://github.com/ohnotnow/agent-issue-tracker";
    license = licenses.mit;
    mainProgram = "ait";
  };
}
