# NixOS VM integration test: boot a machine with the remux service enabled,
# wait for it to come up and confirm it serves the public API.
self: pkgs:
pkgs.testers.runNixOSTest {
  name = "remux-service";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];

      services.remux = {
        enable = true;
        openFirewall = true;
        hardwareAcceleration = false; # the VM has no /dev/dri
        settings.disable_dht = true; # no torrent gossip in the sandbox
      };

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    machine.wait_for_unit("remux.service")
    machine.wait_for_open_port(3000)

    # Jellyfin public endpoint (also exercises case-insensitive routing).
    machine.succeed("curl -sf http://localhost:3000/System/Info/Public | grep -i version")
    machine.succeed("curl -sf http://localhost:3000/system/ping")

    # The bundled web UI and dashboard are served from the store paths the
    # package wired in.
    machine.succeed("curl -sf http://localhost:3000/web/ -o /dev/null")
  '';
}
