{ self, config, lib, pkgs, ... }:

let
  inherit (lib)
    types mkEnableOption mkOption mkIf literalExpression;

  toml = pkgs.formats.toml { };

  cfg = config.services.logos-storage-nim;
in
{
  options = {
    services.logos-storage-nim = {
      enable = mkEnableOption "Logos Storage Node service.";

      package = mkOption {
        type = types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.logos-storage-nim;
        defaultText = literalExpression "self.packages.\${pkgs.stdenv.hostPlatform.system}.logos-storage-nim";
        description = "Package to use as Nim Logos Storage node.";
      };

      settings = mkOption {
        default = { };
        type = toml.type;
        description = ''Structured settings object that will be used to generate a TOML config file.'';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.etc = {
      "logos-storage-nim/config.toml".source = toml.generate "config.toml" cfg.settings;
    };
    systemd.services.logos-storage-nim = {
      description = "Logos Storage Node";
      wantedBy = [ "multi-user.target" ];
      requires = [ "network.target" ];
      serviceConfig = {
        DynamicUser = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        NoNewPrivileges = true;
        PrivateDevices = true;
        MemoryDenyWriteExecute = true;
        ExecStart = "${cfg.package}/bin/storage --config-file=/etc/logos-storage-nim/config.toml";
        Restart = "on-failure";
      };
      restartIfChanged = true;
      restartTriggers = [
        "/etc/logos-storage-nim/config.toml"
      ];
    };
  };
}
