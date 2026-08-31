{
  description = "Minecraft Server";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      defaultJavaPackage = pkgs.jdk21;
      defaultForgeMinecraftVersion = "1.20.1";
      defaultForgeVersion = "47.4.10";

      loaderMeta = import ./loaders { inherit pkgs; };

      makeScripts =
        {
          javaPackage,
          loader,
          minecraftVersion,
          forgeVersion,
          paperBuild,
          packwizUrl,
          serverDir ? null,
        }:
        let
          dir = if serverDir != null then serverDir else "$(pwd)/server";
          meta = loaderMeta.${loader};
          installArgs = {
            inherit javaPackage minecraftVersion paperBuild;
            loaderVersion = forgeVersion;
          };
        in
        {
          install = pkgs.writeShellScriptBin "install-server" ''
            set -e
            echo "Downloading and installing ${loader}..."
            cd "${dir}"
            ${meta.installCmd installArgs}
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
        minecraftVersion = defaultForgeMinecraftVersion;
        forgeVersion = defaultForgeVersion;
        paperBuild = "latest";
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
          routerCfg = config.services.minecraft-router;
        in
        {
          options.services.minecraft-router = {
            enable = mkEnableOption "hostname-based Minecraft router (mc-router)";
            domainSuffix = mkOption {
              type = types.str;
              example = "mc.example.com";
              description = ''
                Domain suffix for server hostnames. Every enabled server in
                services.minecraft-servers is automatically routed as
                <name>.<domainSuffix> — point a single wildcard DNS record
                (*.<domainSuffix>) at this host and new servers need no
                per-server DNS work at all.
              '';
            };
            port = mkOption {
              type = types.port;
              default = 25565;
              description = "Public port the router listens on. Backend servers must use other ports.";
            };
            proxyProtocol = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Forward real client IPs to backends using PROXY protocol.
                Paper/Folia backends parse it natively and are configured
                automatically. Other loaders can't parse the header, so they
                get a local stripper instance of mc-router in front — they
                keep working but still see connections from 127.0.0.1.
              '';
            };
            defaultServer = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Name of the server (attribute name in services.minecraft-servers)
                that receives connections not matching any hostname, e.g.
                players connecting by raw IP.
              '';
            };
            openFirewall = mkOption {
              type = types.bool;
              default = true;
            };
          };

          options.services.minecraft-servers = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, config, ... }:
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
                        "fabric"
                        "paper"
                        "folia"
                      ];
                      default = "forge";
                      description = "Server software to use (Forge, NeoForge, Fabric, Paper, or Folia)";
                    };
                    forgeMinecraftVersion = mkOption {
                      type = types.str;
                      default = defaultForgeMinecraftVersion;
                      description = "Legacy Minecraft version option; prefer minecraftVersion";
                    };
                    minecraftVersion = mkOption {
                      type = types.str;
                      default = config.forgeMinecraftVersion;
                      description = "Minecraft version to install";
                    };
                    forgeVersion = mkOption {
                      type = types.str;
                      default = defaultForgeVersion;
                      description = "Loader version (Forge, NeoForge or Fabric loader version number)";
                    };
                    paperBuild = mkOption {
                      type = types.strMatching "(latest|[1-9][0-9]*)";
                      default = "latest";
                      description = ''
                        PaperMC build ID to install, or "latest" for the newest stable build.
                        Applies to Paper and Folia. Folia plugins must explicitly support Folia.
                      '';
                    };
                    packwizUrl = mkOption {
                      type = types.str;
                      description = "URL to the packwiz pack.toml for the modpack";
                    };
                    acceptsProxyProtocol = mkOption {
                      type = types.nullOr types.bool;
                      default = null;
                      description = ''
                        Whether this server can parse PROXY protocol headers
                        itself. Default (null) decides by loader: true for
                        Paper/Folia, false otherwise. Set true for a modded
                        server with e.g. ProperProxyProtocol installed to
                        skip the stripper and receive real client IPs.
                      '';
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

          config = mkMerge [
            (mkIf routerCfg.enable (
              let
                mcRouter = import ./mc-router.nix { inherit pkgs; };
                enabledServers = filterAttrs (_: s: s.enable) cfg;
                speaksProxyProtocol = s:
                  if s.acceptsProxyProtocol != null then
                    s.acceptsProxyProtocol
                  else
                    elem s.loader [ "paper" "folia" ];
                needsStripper = s: routerCfg.proxyProtocol && !(speaksProxyProtocol s);
                stripPortOffset = 10000;
                # The router must target the stripper (not the server) for
                # backends that can't parse the PROXY header themselves.
                backendPort = s: if needsStripper s then s.port + stripPortOffset else s.port;
                mappings = concatStringsSep "," (
                  mapAttrsToList (
                    name: s: "${name}.${routerCfg.domainSuffix}=127.0.0.1:${toString (backendPort s)}"
                  ) enabledServers
                );
                defaultArg = optionalString (routerCfg.defaultServer != null)
                  " -default 127.0.0.1:${toString (backendPort cfg.${routerCfg.defaultServer})}";
                proxyArg = optionalString routerCfg.proxyProtocol " -use-proxy-protocol";
              in
              {
                assertions = [
                  {
                    assertion = all (s: s.port != routerCfg.port) (attrValues enabledServers);
                    message = "services.minecraft-router.port (${toString routerCfg.port}) collides with a backend server's port — move that server to another port.";
                  }
                ];
                systemd.services = {
                  mc-router = {
                    description = "Minecraft hostname router (mc-router)";
                    wantedBy = [ "multi-user.target" ];
                    after = [ "network.target" ];
                    serviceConfig = {
                      DynamicUser = true;
                      Restart = "always";
                      RestartSec = "5s";
                      ExecStart = "${mcRouter}/bin/mc-router -port ${toString routerCfg.port} -mapping ${escapeShellArg mappings}${proxyArg}${defaultArg}";
                    };
                  };
                } // mapAttrs' (name: s:
                  nameValuePair "mc-router-strip-${name}" {
                    description = "PROXY protocol stripper for Minecraft server ${name}";
                    wantedBy = [ "multi-user.target" ];
                    after = [ "network.target" ];
                    serviceConfig = {
                      DynamicUser = true;
                      Restart = "always";
                      RestartSec = "5s";
                      ExecStart = "${mcRouter}/bin/mc-router -port ${toString (s.port + stripPortOffset)} -receive-proxy-protocol -trusted-proxies 127.0.0.1/32 -default 127.0.0.1:${toString s.port}";
                    };
                  }
                ) (filterAttrs (_: s: needsStripper s) enabledServers);
                networking.firewall.allowedTCPPorts = mkIf routerCfg.openFirewall [ routerCfg.port ];
              }
            ))
            (mkIf (cfg != { }) {
            users.users.minecraft = {
              isSystemUser = true;
              group = "minecraft";
              home = "/srv/minecraft";
              createHome = true;
            };
            users.groups.minecraft = { };

            # Users in this group get read/write access to all server directories
            # and can attach to screen sessions without a password.
            users.groups.minecraft-admin = { };

            # Allow minecraft-admin members to run screen -r as the minecraft
            # user without a password. Scoped to screen only — not a full sudo.
            security.sudo.extraRules = [
              {
                groups = [ "minecraft-admin" ];
                runAs = "minecraft";
                commands = [
                  {
                    command = "${pkgs.screen}/bin/screen -r minecraft-*";
                    options = [ "NOPASSWD" "SETENV" ];
                  }
                ];
              }
            ];

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
                scripts = makeScripts {
                  inherit (serverCfg)
                    javaPackage
                    loader
                    minecraftVersion
                    forgeVersion
                    paperBuild
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
                  chown minecraft:minecraft-admin ${serverDir}
                  chmod 2770 ${serverDir}

                  for file in ops.json whitelist.json banned-players.json banned-ips.json; do
                    if [ ! -s "${serverCfg.configPath}/$file" ]; then
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

                  # The port option is authoritative: the router maps to it, so the
                  # server must actually bind it, whatever server.properties says.
                  if [ -f ${serverDir}/server.properties ] && grep -q '^server-port=' ${serverDir}/server.properties; then
                    sed -i 's/^server-port=.*/server-port=${toString serverCfg.port}/' ${serverDir}/server.properties
                  else
                    echo 'server-port=${toString serverCfg.port}' >> ${serverDir}/server.properties
                  fi

                  # Behind the router with PROXY protocol on, Paper-family
                  # servers must accept the header or every connection fails.
                  ${optionalString
                    (routerCfg.enable && routerCfg.proxyProtocol
                      && elem serverCfg.loader [ "paper" "folia" ]) ''
                    mkdir -p ${serverDir}/config
                    if grep -q 'proxy-protocol:' ${serverDir}/config/paper-global.yml 2>/dev/null; then
                      sed -i 's/proxy-protocol: false/proxy-protocol: true/' ${serverDir}/config/paper-global.yml
                    else
                      printf 'proxies:\n  proxy-protocol: true\n' >> ${serverDir}/config/paper-global.yml
                    fi
                  ''}
                '';

                script =
                  let
                    cmd = meta.launchCmd {
                      inherit (serverCfg) javaPackage ramGb;
                      inherit serverDir;
                      minecraftVersion = serverCfg.minecraftVersion;
                      loaderVersion = serverCfg.forgeVersion;
                    };
                  in
                  ''
                    export SCREENDIR=${serverDir}/.screen
                    mkdir -p "$SCREENDIR"
                    chmod 700 "$SCREENDIR"
                    ${pkgs.screen}/bin/screen -S minecraft-${name} -X quit >/dev/null 2>&1 || true
                    ${pkgs.screen}/bin/screen -L -Logfile ${serverDir}/console.log -dmS minecraft-${name} \
                      ${cmd}
                    sleep 5
                    while ${pkgs.screen}/bin/screen -ls | grep -q "minecraft-${name}"; do
                      sleep 2
                    done
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

            # mode 2770: setgid so new files created inside inherit the
            # minecraft-admin group; rwxrwx--- restricts access to owner+group only.
            systemd.tmpfiles.rules = lib.mkIf (cfg != { }) (
              (mapAttrsToList (name: serverCfg: "d /srv/minecraft/${name} 2770 minecraft minecraft-admin -") (
                lib.filterAttrs (_: s: s.enable) cfg
              ))
              ++ [
                "d /srv/minecraft 2770 minecraft minecraft-admin -"
                "d /srv/minecraft/global-config 2770 minecraft minecraft-admin -"
              ]
            );

            environment.systemPackages =
              (mapAttrsToList (
                name: serverCfg:
                pkgs.writeShellScriptBin "console-${name}" ''
                  while true; do
                    TERM=xterm SCREENDIR=/srv/minecraft/${name}/.screen sudo -E -u minecraft ${pkgs.screen}/bin/screen -r minecraft-${name}
                    echo "Screen session detached or unavailable, retrying in 3 seconds..."
                    sleep 3
                  done
                ''
              ) (filterAttrs (_: s: s.enable) cfg))
              ++ (mapAttrsToList (
                name: serverCfg:
                pkgs.writeShellScriptBin "edit-${name}" ''
                  cd /srv/minecraft/${name}
                  exec ''${EDITOR:-nano} .
                ''
              ) (filterAttrs (_: s: s.enable) cfg));
            })
          ];
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
