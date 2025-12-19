# MakerNexus Python development shell
# Activate with: nix develop ~/nix-configs#makernexus
{ pkgs }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Python 3.11 (compatible with >=3.9, <4.0)
    python311

    # Package management
    uv

    # Google Cloud CLI for authentication
    google-cloud-sdk

    # Useful dev tools
    jq
  ];

  # Required for grpc and other native Python packages
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  shellHook = ''
    echo "MakerNexus Python dev environment"
    echo "Python: $(python --version)"
    echo ""
    echo "Setup instructions:"
    echo "  1. cd to makernexus-py project directory"
    echo "  2. Run 'uv sync --python \$(which python3)' to install Python dependencies"
    echo "  3. Run 'uv pip install -e .' to install the package"
    echo "  4. Run 'gcloud auth application-default login' for GCP auth"
    echo ""

    # Activate the virtual environment if it exists
    if [ -d ".venv" ]; then
      source .venv/bin/activate
    fi
  '';
}
