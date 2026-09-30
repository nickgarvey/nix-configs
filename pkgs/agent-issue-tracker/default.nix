{ buildGoModule, fetchFromGitHub, lib }:

buildGoModule rec {
  pname = "agent-issue-tracker";
  # Our fork is untagged; version follows the nixpkgs unstable convention,
  # base version from the last upstream release we forked past.
  version = "1.15.0-unstable-2026-09-30";

  src = fetchFromGitHub {
    owner = "nickgarvey";
    repo = "agent-issue-tracker";
    rev = "1de7c2ff9c072b9cceacbed6f95c9190c69d1c9e";
    hash = "sha256-dBnGtxa/lG3q13K5Uf4GfuVmZI/rcpbs/IifobJ97Vo=";
  };

  vendorHash = "sha256-+jdz9R40HGu2sS2RCN+Q2qh/8FskscJZz5Jo3NlAxbA=";

  # The `ait` binary; the repo root holds no main package.
  subPackages = [ "cmd/ait" ];

  # Same stamping as upstream's release workflow, so `ait version` reports a
  # real version instead of "dev". The module path still says ohnotnow.
  ldflags = [
    "-X github.com/ohnotnow/agent-issue-tracker/internal/ait.Version=${version}"
  ];

  meta = with lib; {
    description = "Local-first issue tracker for coding agents (personal fork)";
    homepage = "https://github.com/nickgarvey/agent-issue-tracker";
    license = licenses.mit;
    mainProgram = "ait";
  };
}
