{
  description = "Minecraft Server";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      defaultJavaPackage = pkgs.jdk17;
      defaultForgeMinecraftVersion = "1.20.1";
      defaultForgeVersion = "47.4.10";

      loaderMeta = {
        forge = {
          installerUrl =
            { minecraftVersion, loaderVersion }:
            "https://maven.minecraftforge.net/net/minecraftforge/forge/${minecraftVersion}-${loaderVersion}/forge-${minecraftVersion}-${loaderVersion}-installer.jar";
          installerJar =
            { minecraftVersion, loaderVersion }: "forge-${minecraftVersion}-${loaderVersion}-installer.jar";
          unixArgsPath =
            { minecraftVersion, loaderVersion }:
            "libraries/net/minecraftforge/forge/${minecraftVersion}-${loaderVersion}/unix_args.txt";
        };
        neoforge = {
          installerUrl =
            { minecraftVersion, loaderVersion }:
            "https://maven.neoforged.net/releases/net/neoforged/neoforge/${loaderVersion}/neoforge-${loaderVersion}-installer.jar";
          installerJar = { minecraftVersion, loaderVersion }: "neoforge-${loaderVersion}-installer.jar";
          unixArgsPath =
            { minecraftVersion, loaderVersion }:
            "libraries/net/neoforged/neoforge/${loaderVersion}/unix_args.txt";
        };
      };

      makeScripts =
        {
          javaPackage,
          loader,
          forgeMinecraftVersion,
          forgeVersion,
          packwizUrl,
          serverDir ? null,
        }:
        let
          dir = if serverDir != null then serverDir else "$(pwd)/server";
          meta = loaderMeta.${loader};
          urlArgs = {
            minecraftVersion = forgeMinecraftVersion;
            loaderVersion = forgeVersion;
          };
        in
        {
          install = pkgs.writeShellScriptBin "install-server" ''
            set -e
            echo "Downloading and installing ${loader}..."
            cd "${dir}"
            ${pkgs.wget}/bin/wget ${meta.installerUrl urlArgs}
            ${javaPackage}/bin/java -jar ${meta.installerJar urlArgs} --installServer
          '';
          update = pkgs.writeShellScriptBin "update-server" ''
            set -e
            echo "Running updates with packwiz..."
            cd "${dir}"
            ${javaPackage}/bin/java -jar packwiz-installer-bootstrap.jar --bootstrap-no-update -g -s server ${packwizUrl}
          '';
        };

      devScripts = makeScripts {
        javaPackage = defaultJavaPackage;
        loader = "forge";
        forgeMinecraftVersion = defaultForgeMinecraftVersion;
        forgeVersion = defaultForgeVersion;
        packwizUrl = "./modpack/pack.toml";
      };
    in
    {
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        with lib;
        let
          cfg = config.services.minecraft-servers;
        in
        {
          options.services.minecraft-servers = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, ... }:
                {
                  options = {
                    enable = mkEnableOption "Minecraft modpack server";
                    configPath = mkOption {
                      type = types.str;
                      default = "/srv/minecraft/global-config";
                      description = "Path containing shared ops.json, whitelist.json, etc.";
                    };
                    acceptEULA = mkOption {
                      type = types.bool;
                      default = false;
                    };
                    openFirewall = mkOption {
                      type = types.bool;
                      default = false;
                    };
                    port = mkOption {
                      type = types.port;
                      default = 25565;
                    };
                    javaPackage = mkOption {
                      type = types.package;
                      default = defaultJavaPackage;
                    };
                    loader = mkOption {
                      type = types.enum [
                        "forge"
                        "neoforge"
                      ];
                      default = "forge";
                      description = "Mod loader to use (forge or neoforge)";
                    };
                    forgeMinecraftVersion = mkOption {
                      type = types.str;
                      default = defaultForgeMinecraftVersion;
                    };
                    forgeVersion = mkOption {
                      type = types.str;
                      default = defaultForgeVersion;
                      description = "Loader version (Forge or NeoForge version number)";
                    };
                    packwizUrl = mkOption {
                      type = types.str;
                      description = "URL to the packwiz pack.toml for the modpack";
                    };
                    ramGb = mkOption {
                      type = types.int;
                      default = 4;
                      description = "RAM allocated to the server in GB";
                    };
                  };
                }
              )
            );
            default = { };
            description = "Minecraft modpack server instances";
          };

          config = mkIf (cfg != { }) {
            users.users.minecraft = {
              isSystemUser = true;
              group = "minecraft";
              home = "/srv/minecraft";
              createHome = true;
            };
            users.groups.minecraft = { };

            networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: s: s.port) (
              lib.filterAttrs (_: s: s.openFirewall) cfg
            );

            networking.firewall.allowedUDPPorts = lib.mapAttrsToList (_: s: s.port) (
              lib.filterAttrs (_: s: s.openFirewall) cfg
            );

            systemd.services = mapAttrs' (
              name: serverCfg:
              let
                serverDir = "/srv/minecraft/${name}";
                meta = loaderMeta.${serverCfg.loader};
                urlArgs = {
                  minecraftVersion = serverCfg.forgeMinecraftVersion;
                  loaderVersion = serverCfg.forgeVersion;
                };
                scripts = makeScripts {
                  inherit (serverCfg)
                    javaPackage
                    loader
                    forgeMinecraftVersion
                    forgeVersion
                    packwizUrl
                    ;
                  inherit serverDir;
                };
              in
              nameValuePair "minecraft-${name}" {
                description = "Minecraft Server (${name})";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                path = [
                  serverCfg.javaPackage
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.curl
                  pkgs.wget
                  pkgs.screen
                ];

                preStart = ''
                  mkdir -p ${serverDir}
                  chown minecraft:minecraft ${serverDir}

                  for file in ops.json whitelist.json banned-players.json banned-ips.json; do
                    if [ ! -f "${serverCfg.configPath}/$file" ]; then
                      echo '[]' > "${serverCfg.configPath}/$file"
                    fi
                    ln -sf "${serverCfg.configPath}/$file" "${serverDir}/$file"
                  done

                  # Write eula.txt as the service user (minecraft) so we own it and can manage it.
                  ${optionalString serverCfg.acceptEULA ''
                    echo 'eula=true' > ${serverDir}/eula.txt
                  ''}

                  if [ ! -f ${serverDir}/.installed ]; then
                    cp -r ${self}/server/. ${serverDir}/
                    # Make everything writable now that we own all files.
                    chmod -R u+w ${serverDir}
                    ${scripts.install}/bin/install-server
                    touch ${serverDir}/.installed
                  fi

                  ${scripts.update}/bin/update-server
                '';

                script = ''
                  exec ${pkgs.screen}/bin/screen -DmS minecraft-${name} \
                    ${serverCfg.javaPackage}/bin/java \
                    -Xmx${toString serverCfg.ramGb}G \
                    -Xms${toString serverCfg.ramGb}G \
                    @${serverDir}/${meta.unixArgsPath urlArgs} \
                    nogui
                '';

                serviceConfig = {
                  User = "minecraft";
                  Group = "minecraft";
                  WorkingDirectory = serverDir;
                  PermissionsStartOnly = false;
                  Restart = "always";
                  RestartSec = "10s";
                  TimeoutStopSec = "60s";
                  KillSignal = "SIGTERM";
                };
              }
            ) (filterAttrs (_: s: s.enable) cfg);

            systemd.tmpfiles.rules = lib.mkIf (cfg != { }) (
              (mapAttrsToList (name: serverCfg: "d /srv/minecraft/${name} 0755 minecraft minecraft -") (
                lib.filterAttrs (_: s: s.enable) cfg
              ))
              ++ [
                "d /srv/minecraft/global-config 0755 minecraft minecraft -"
              ]
            );

            environment.systemPackages = mapAttrsToList (
              name: serverCfg:
              pkgs.writeShellScriptBin "console-${name}" ''
                sudo -u minecraft bash -c '
                  while true; do
                    TERM=xterm ${pkgs.screen}/bin/screen -r minecraft-${name}
                    echo "Screen session detached or unavailable, retrying in 3 seconds..."
                    sleep 3
                  done
                '
              ''
            ) (filterAttrs (_: s: s.enable) cfg);
          };
        };

      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          defaultJavaPackage
          pkgs.wget
          pkgs.curl
          pkgs.bash
          pkgs.screen
          devScripts.install
          devScripts.update
          pkgs.packwiz
        ];
      };
    };
}
