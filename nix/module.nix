# NixOS module for the remux media server.
#
# Usage (flake):
#   imports = [ remux.nixosModules.default ];
#   services.remux.enable = true;
#
# `self` is the flake, used to pick the default package for the host system.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.remux;

  # Configuration is rendered to a TOML file that the server reads via the
  # CONFIG env var. Field names match the Rust `Config` struct (snake_case).
  settingsFormat = pkgs.formats.toml { };

  # The dedicated `port`/`dataDir` options always win over `settings`.
  finalSettings = cfg.settings // {
    data_dir = cfg.dataDir;
    port = cfg.port;
  };

  configFile = settingsFormat.generate "remux-config.toml" finalSettings;
in
{
  options.services.remux = {
    enable = lib.mkEnableOption "the remux media server";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.remux;
      defaultText = lib.literalExpression "remux.packages.\${system}.remux";
      description = "The assembled remux package to run (server + web assets + ffmpeg/yt-dlp).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "remux";
      description = "User account under which remux runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "remux";
      description = "Group under which remux runs.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/remux";
      description = ''
        Directory for the SQLite database, torrents and other server state.
        Created automatically with the right ownership. Maps to the server's
        `data_dir` setting.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "TCP port the HTTP server listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open {option}`services.remux.port` in the firewall.";
    };

    hardwareAcceleration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Grant the service access to `/dev/dri` (the `video` and `render`
        groups) so jellyfin-ffmpeg can use VAAPI / QSV hardware transcoding.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/remux.env";
      description = ''
        Path to an EnvironmentFile (e.g. for secrets or extra env vars such as
        `RUST_LOG` or `HTTPS_PROXY`). Loaded by systemd, not world-readable.
      '';
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          slow_query_threshold_ms = 700;
          disable_dht = true;
          torrent_peer_port = 6881;
        }
      '';
      description = ''
        Free-form server configuration, rendered to a TOML file. Keys match the
        server's `Config` fields (snake_case): `torrent_http_port`,
        `slow_query_threshold_ms`, `disable_dht`, `torrent_peer_port`,
        `bgutil_script_path`, `tmdb_base_url`, `trakt_base_url`, etc.

        `data_dir` and `port` are controlled by the dedicated options above and
        take precedence over anything set here. `web_path`, `dashboard_path`
        and the ffmpeg paths are provided by the package and need not be set.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.mkIf (cfg.user == "remux") {
      remux = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        description = "remux media server";
      };
    };

    users.groups = lib.mkIf (cfg.group == "remux") {
      remux = { };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    systemd.services.remux = {
      description = "remux media server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment.CONFIG = configFile;

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 5;

        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [ cfg.dataDir ];
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;

        SupplementaryGroups = lib.optionals cfg.hardwareAcceleration [
          "video"
          "render"
        ];

        # Hardening (kept compatible with /dev/dri transcoding and networking).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };
  };
}
