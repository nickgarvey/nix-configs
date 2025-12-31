{
  description = "Hidden NodeJS for Cursor remote sessions (CURSOR_REMOTE=1)";

  outputs = { self }:
  {
    nixosModules.cursor-remote-node =
      { lib, pkgs, config, ... }:
      let
        cfg = config.cursorRemoteNode;
      in
      {
        options.cursorRemoteNode = {
          enable = lib.mkEnableOption "Expose NodeJS only when CURSOR_REMOTE=1 (for Cursor remote)";

          nodePackage = lib.mkOption {
            type = lib.types.package;
            default = pkgs.nodejs_22;  # or pkgs.nodejs_20 for LTS
            description = ''
              NodeJS package to expose to remote sessions when CURSOR_REMOTE=1.
            '';
          };
        };

        config = lib.mkIf cfg.enable {
          # Ensure the node package is built / available on the system
          environment.systemPackages = [ cfg.nodePackage ];

          # Allow the CURSOR_REMOTE env var to be passed in via SSH
          services.openssh.settings.AcceptEnv = [ "CURSOR_REMOTE" ];

          # Only add Node to PATH if CURSOR_REMOTE=1
          environment.loginShellInit = ''
            if [ "''${CURSOR_REMOTE-}" = "1" ]; then
              export PATH=${cfg.nodePackage}/bin:"$PATH"
            fi
          '';
        };
      };
  };
}

