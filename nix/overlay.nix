# Overlay that adds the remux packages to a nixpkgs package set.
#   remux-server     – the bare Rust server binary
#   remux-dashboard  – the Dioxus/WASM admin UI
#   remux            – the assembled, runnable server (binary wrapped with its
#                      web assets, ffmpeg and yt-dlp)
#
# `src` is passed in (the flake source) so the overlay stays pure.
src:
final: prev:
let
  inherit (final) lib;

  version = "0.0.0";

  # Lean source tree: only the Rust workspace bits the builds touch. Using
  # lib.fileset (rather than cleanSourceWith) keeps the derived source
  # content-addressed — editing docs, nix/ or the flake itself does not change
  # rustSrc, so the (slow) Rust builds stay cached across unrelated edits.
  rustSrc = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.unions [
      (src + "/Cargo.toml")
      (src + "/Cargo.lock")
      (src + "/crates")
    ];
  };

  cargoLock.lockFile = rustSrc + "/Cargo.lock";

  # dx ships with the `no-downloads` feature, so it uses tools from PATH. It is
  # wired to wasm-bindgen-cli 0.2.118, but this project pins 0.2.114 and the two
  # versions must match exactly — swap it via the input arg.
  dx = final.dioxus-cli.override {
    "wasm-bindgen-cli_0_2_118" = final.wasm-bindgen-cli_0_2_114;
  };

  # bgutil-pot: prebuilt POT-provider binary (YouTube proof-of-origin tokens).
  # Matches the version baked into docker/Dockerfile.
  bgutilVersion = "0.8.1";
  bgutilBinHashes = {
    x86_64-linux = "sha256-58JkpXT6JwW25dxiKDqKToATDye51+nfROawmqYVGoc=";
    aarch64-linux = "sha256-T0ofaB26ReaV4cFNMUUX2hgKH9N0r9CdY0/YDvbQKEs=";
  };
  bgutilArch =
    {
      x86_64-linux = "x86_64";
      aarch64-linux = "aarch64";
    }
    .${final.stdenv.hostPlatform.system} or (throw "bgutil-pot: unsupported system ${final.stdenv.hostPlatform.system}");

  bgutil-pot = final.stdenvNoCC.mkDerivation {
    pname = "bgutil-pot";
    version = bgutilVersion;
    src = final.fetchurl {
      url = "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/v${bgutilVersion}/bgutil-pot-linux-${bgutilArch}";
      hash = bgutilBinHashes.${final.stdenv.hostPlatform.system};
    };
    dontUnpack = true;
    nativeBuildInputs = [ final.autoPatchelfHook ];
    buildInputs = [
      final.stdenv.cc.cc.lib
      final.openssl # libssl.so.3 / libcrypto.so.3
    ];
    installPhase = "install -Dm755 $src $out/bin/bgutil-pot";
    meta = {
      description = "bgutil POT provider for yt-dlp (YouTube proof-of-origin tokens)";
      mainProgram = "bgutil-pot";
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

  # The companion yt-dlp plugin (provides the `youtubepot-bgutilscript`
  # extractor that shells out to the bgutil-pot binary). Exposed as a directory
  # suitable for YTDLP_PLUGIN_DIRS (contains a top-level yt_dlp_plugins/).
  bgutil-pot-plugin = final.stdenvNoCC.mkDerivation {
    pname = "bgutil-ytdlp-pot-provider-plugin";
    version = bgutilVersion;
    src = final.fetchurl {
      url = "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/v${bgutilVersion}/bgutil-ytdlp-pot-provider-rs.zip";
      hash = "sha256-mf2DuY+pOxk9ajtp3HRBDXbnoriJhoxU0WEhyskGA0Q=";
    };
    nativeBuildInputs = [ final.unzip ];
    unpackPhase = "unzip $src -d unpacked";
    installPhase = ''
      mkdir -p $out
      cp -r unpacked/yt_dlp_plugins $out/
    '';
    meta.description = "yt-dlp plugin dir for the bgutil POT provider";
  };

  # jellyfin-web pinned to the exact tag the project targets (v10.11.9).
  # nixpkgs ships 10.11.11; rather than override it (buildNpmPackage computes
  # its deps from outer args, so overrideAttrs can't re-point src+npmDepsHash,
  # and the upstream `src` carries an `assert version == jellyfin.version`),
  # we rebuild it from the same short recipe with the pinned source.
  jellyfin-web = final.buildNpmPackage (finalAttrs: {
    pname = "jellyfin-web";
    version = "10.11.9";

    src = final.fetchFromGitHub {
      owner = "jellyfin";
      repo = "jellyfin-web";
      rev = "ec519022e29fee29cef025b8e381a2982488a286"; # v10.11.9
      hash = "sha256-+WKFwnMjDX6HK5+6HVJyppFspbuuuKGtc8jCR4hqBL4=";
    };

    nodejs = final.nodejs_22;

    postPatch = ''
      substituteInPlace webpack.common.js \
        --replace-fail "git describe --always --dirty" "echo ${finalAttrs.src.rev}"
    '';

    npmDepsHash = "sha256-dXQaUPIYnUn9tPbAk8aDhkW1nOFRCMDwqPfgUi6FLMg=";

    preBuild = ''
      # sass-embedded ships a prebuilt dart binary that fails in the sandbox.
      rm -r node_modules/sass-embedded*
    '';

    npmBuildScript = [ "build:production" ];

    nativeBuildInputs = [ final.pkg-config ];
    buildInputs = [ final.pango ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share
      cp -a dist $out/share/jellyfin-web
      runHook postInstall
    '';

    meta = {
      description = "Web Client for Jellyfin (pinned to v10.11.9)";
      homepage = "https://jellyfin.org/";
      license = lib.licenses.gpl2Plus;
    };
  });
in
{
  inherit bgutil-pot bgutil-pot-plugin jellyfin-web;

  remux-server = final.rustPlatform.buildRustPackage {
    pname = "remux-server";
    inherit version cargoLock;
    src = rustSrc;

    cargoBuildFlags = [ "--package" "remux-server" ];
    SQLX_OFFLINE = "true";
    doCheck = false;

    nativeBuildInputs = with final; [
      pkg-config
      cmake # aws-lc-sys
      perl # ring / aws-lc-sys
    ];

    meta = {
      description = "Jellyfin-compatible media server written in Rust";
      mainProgram = "remux-server";
      platforms = lib.platforms.linux;
    };
  };

  remux-dashboard = final.rustPlatform.buildRustPackage {
    pname = "remux-dashboard";
    inherit version cargoLock;
    src = rustSrc;

    nativeBuildInputs = [
      dx
      final.binaryen # wasm-opt
      final.lld # dioxus links wasm via lld / wasm-ld
    ];

    buildPhase = ''
      runHook preBuild
      export HOME=$(mktemp -d)
      ( cd crates/remux-dashboard && dx build --release --platform web )
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r target/dx/*/release/web/public/. $out/
      runHook postInstall
    '';

    doCheck = false;

    meta = {
      description = "remux admin dashboard (Dioxus WASM)";
      platforms = lib.platforms.all;
    };
  };

  remux = final.stdenv.mkDerivation {
    pname = "remux";
    inherit version;

    dontUnpack = true;
    nativeBuildInputs = [ final.makeWrapper ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      makeWrapper ${final.remux-server}/bin/remux-server $out/bin/remux-server \
        --set-default WEB_PATH ${final.jellyfin-web}/share/jellyfin-web \
        --set-default DASHBOARD_PATH ${final.remux-dashboard} \
        --set-default FFMPEG_PATH ${final.jellyfin-ffmpeg}/bin/ffmpeg \
        --set-default FFPROBE_PATH ${final.jellyfin-ffmpeg}/bin/ffprobe \
        --set-default BGUTIL_SCRIPT_PATH ${final.bgutil-pot}/bin/bgutil-pot \
        --suffix PYTHONPATH : ${final.bgutil-pot-plugin} \
        --prefix PATH : ${lib.makeBinPath [ final.yt-dlp final.jellyfin-ffmpeg ]}
      runHook postInstall
    '';

    passthru = {
      inherit (final) remux-server remux-dashboard;
      jellyfin-web = final.jellyfin-web;
    };

    meta = {
      description = "Jellyfin-compatible media server (server + dashboard + jellyfin-web + ffmpeg/yt-dlp)";
      mainProgram = "remux-server";
      platforms = lib.platforms.linux;
    };
  };
}
