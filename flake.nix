{
  description = "remux — Jellyfin-compatible media server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Overlay adds remux-server / remux-dashboard / remux to a package set.
      # Pass the flake dir as a path (not `self`) so lib.fileset can scope the
      # Rust source precisely.
      overlay = import ./nix/overlay.nix ./.;
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      {
        packages = {
          inherit (pkgs)
            remux-server
            remux-dashboard
            remux
            jellyfin-web
            bgutil-pot
            bgutil-pot-plugin
            ;
          default = pkgs.remux;
        };

        # `nix run` to launch the assembled server ad-hoc. The server opens its
        # SQLite db with mode=rwc, which creates the file but not its parent
        # dir, so ensure the data dir exists first. (The NixOS module creates
        # it via tmpfiles; this only matters for ad-hoc runs.)
        apps.default = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellScriptBin "remux" ''
              mkdir -p "''${DATA_DIR:-$HOME/.local/share/remux}"
              exec ${pkgs.remux}/bin/remux-server "$@"
            ''
          );
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ pkgs.remux-server ];
          packages = with pkgs; [
            dioxus-cli
            cargo-make
            jellyfin-ffmpeg
            yt-dlp
          ];
        };

        # NixOS VM test (Linux only): boots the service and curls it.
        checks = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          vm-test = import ./nix/test.nix self pkgs;
        };
      }
    )
    // {
      overlays.default = overlay;
      nixosModules.default = import ./nix/module.nix self;
    };
}
