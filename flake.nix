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
          webCfg = config.services.minecraft-web;
          metricsCfg = config.services.minecraft-metrics;
          # Loopback RCON for the lag auto-profiler lives at port+offset,
          # far from the router's stripper range (port+10000).
          rconPortOffset = 20000;
        in
        {
          options.services.minecraft-web = {
            enable = mkEnableOption "static modpack listing website with install links";
            hostName = mkOption {
              type = types.str;
              example = "packs.mc.example.com";
              description = ''
                Domain to serve the site on (nginx virtual host). A subdomain
                of the router's wildcard record needs no extra DNS work.
              '';
            };
            enableACME = mkOption {
              type = types.bool;
              default = true;
              description = "Get a certificate and force HTTPS for the site.";
            };
            sparkReportsPort = mkOption {
              type = types.port;
              default = 3002;
              description = ''
                Port the captured .sparkprofile files + index are served on
                (only when some server sets sparkOnLag). Reuses the metrics
                module's TLS cert and exposeInterfaces, i.e. tailnet-only in
                the standard setup.
              '';
            };
            dashboardUrl = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "https://myhost.tailnet.ts.net";
              description = ''
                URL of the Grafana metrics dashboard. When set, the site shows
                a small graph link next to each TPS readout — but only after a
                client-side reachability probe of <url>/api/health succeeds,
                so visitors who can't reach the dashboard (e.g. it's only
                exposed on a tailnet) never see the link at all.
              '';
            };
          };

          options.services.minecraft-metrics = {
            enable = mkEnableOption ''
              Prometheus + Grafana for the servers' exported metrics. Both
              listen on loopback only — expose Grafana however you like
              (e.g. `tailscale serve` for tailnet-only access governed by ACLs)
            '';
            prometheusPort = mkOption {
              type = types.port;
              default = 9090;
            };
            grafanaPort = mkOption {
              type = types.port;
              default = 3000;
            };
            grafanaDomain = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "myhost.tailnet.ts.net";
              description = ''
                Domain Grafana is reached at (sets root_url so redirects and
                cookies work). Plain http on <grafanaPort>.
              '';
            };
            exposeInterfaces = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "tailscale0" ];
              description = ''
                Interfaces to open grafanaPort on. When non-empty Grafana
                binds all addresses but the firewall only admits these
                interfaces — e.g. [ "tailscale0" ] gives tailnet-only access
                governed by tailscale ACLs. Empty = loopback only.
              '';
            };
            tlsCertFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "/etc/ssl/tailscale-certs/cert.pem";
              description = ''
                Serve Grafana over HTTPS with this certificate (e.g. the
                tailscale-issued host cert). Both tlsCertFile and tlsKeyFile
                must be set; the grafana user needs read access.
              '';
            };
            tlsKeyFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "/etc/ssl/tailscale-certs/key.pem";
            };
          };

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
            recordLogins = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Keep a persistent connection log: the router webhooks every
                player connect/disconnect (name, UUID, client IP, requested
                server) to a loopback collector that appends JSON lines to
                /var/lib/minecraft-login-log/logins.jsonl. Readable by the
                minecraft-admin group; summarise with `mc-logins`.
              '';
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
                    aikarFlags = mkOption {
                      type = types.bool;
                      default = true;
                      description = ''
                        Launch with Aikar's flags (https://mcflags.emc.gs) —
                        the community-standard G1 tuning that trades stock
                        ergonomics' long stop-the-world mixed collections for
                        gradual concurrent work, taming GC-driven lag spikes.
                        Tunes within ramGb; needs no extra headroom. Disable
                        for plain -Xmx/-Xms.
                      '';
                    };
                    exportPrometheus = mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Manage the config of the cpburnz "Prometheus Exporter"
                        mod (forge/fabric/neoforge only) so it listens on
                        127.0.0.1:<metricsPort>, where the status site's poller
                        and Prometheus scrape it for TPS. The mod jar itself
                        must be shipped by the modpack from a trusted platform
                        (`packwiz curseforge add prometheus-exporter`,
                        side=server) — jars are never downloaded ad hoc. A log
                        warning is emitted if the mod is missing, and for
                        paper/folia, which have no exporter on a trusted
                        platform.
                      '';
                    };
                    sparkOnLag = mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Auto-profile lag spikes: when the status poller sees
                        TPS below its threshold (default 15), it runs a 60s
                        `spark profiler` over loopback RCON and appends the
                        report URL — which names the chunks/entities burning
                        the tick — to /var/lib/minecraft-web/lag-reports.jsonl
                        (see `mc-lag-reports`). RCON is enabled on loopback
                        with a host-generated password automatically, and the
                        spark mod is overlaid onto the pack from its official
                        Modrinth listing (sha512-verified) on forge/fabric/
                        neoforge; paper/folia bundle spark since 1.21.
                        Requires services.minecraft-web (the poller).
                      '';
                    };
                    metricsPort = mkOption {
                      type = types.nullOr types.port;
                      default = null;
                      description = ''
                        Loopback port of a Prometheus /metrics endpoint for this
                        server (e.g. the Prometheus Exporter mod). The status
                        poller scrapes 127.0.0.1:<metricsPort> for TPS and player
                        metrics. When exportPrometheus is true this also sets the
                        listen port in the managed exporter config (defaults to
                        19565 if left null).
                      '';
                    };
                  };
                }
              )
            );
            default = { };
            description = "Minecraft modpack server instances";
          };

          config = mkMerge [
            (mkIf webCfg.enable (
              let
                enabledWebServers = filterAttrs (_: s: s.enable) cfg;
                webDomainSuffix = if routerCfg.enable then routerCfg.domainSuffix else null;
                webPublicPort = if routerCfg.enable then routerCfg.port else 25565;
                addressOf =
                  name:
                  if webDomainSuffix == null then
                    null
                  else
                    "${name}.${webDomainSuffix}"
                    + (if webPublicPort == 25565 then "" else ":${toString webPublicPort}");
                # Port the poller scrapes for TPS: the auto-installed exporter's
                # port when exportPrometheus is on, else an explicit metricsPort.
                scrapePortOf =
                  s:
                  if s.exportPrometheus then
                    (if s.metricsPort != null then s.metricsPort else 19565)
                  else
                    s.metricsPort;
                # Candidate pack-icon URLs: siblings of the packwiz pack.toml.
                iconUrlsOf =
                  s:
                  let
                    base = replaceStrings [ "pack.toml" ] [ "" ] s.packwizUrl;
                  in
                  map (f: base + f) [
                    "icon.png"
                    "pack.png"
                    "logo.png"
                  ];
                isClientLoader =
                  s:
                  elem s.loader [
                    "forge"
                    "neoforge"
                    "fabric"
                  ];
                # Same rule as the router: paper/folia parse PROXY protocol
                # natively, so when the router runs in proxyProtocol mode the
                # poller's direct pings must send the header too or the
                # backend drops them (and the card shows a false "offline").
                speaksProxyProtocol =
                  s:
                  if s.acceptsProxyProtocol != null then
                    s.acceptsProxyProtocol
                  else
                    elem s.loader [
                      "paper"
                      "folia"
                    ];
                statusConfig = pkgs.writeText "minecraft-web-status.json" (
                  builtins.toJSON (
                    {
                      servers = mapAttrsToList (
                      name: s:
                      {
                        inherit name;
                        inherit (s) port loader packwizUrl;
                        address = addressOf name;
                        metricsPort = scrapePortOf s;
                        iconUrls = if isClientLoader s then iconUrlsOf s else [ ];
                        proxyProtocol = routerCfg.enable && routerCfg.proxyProtocol && speaksProxyProtocol s;
                      }
                      // optionalAttrs s.sparkOnLag {
                        rconPort = s.port + rconPortOffset;
                        rconPasswordFile = "/var/lib/minecraft-rcon/${name}";
                      }
                      ) enabledWebServers;
                    }
                    // statusExtra
                  )
                );
                anySparkOnLag = any (s: s.sparkOnLag) (attrValues enabledWebServers);
                metricsTls = metricsCfg.enable && metricsCfg.tlsCertFile != null && metricsCfg.tlsKeyFile != null;
                reportsBaseUrl =
                  if metricsCfg.enable && metricsCfg.grafanaDomain != null then
                    "http${optionalString metricsTls "s"}://${metricsCfg.grafanaDomain}:${toString webCfg.sparkReportsPort}"
                  else
                    null;
                statusExtra = {
                  reportsBaseUrl = reportsBaseUrl;
                }
                // optionalAttrs metricsCfg.enable {
                  # Lag-report annotations, posted with the host-generated
                  # admin password (made group-readable in the metrics module).
                  grafana = {
                    url = "http${optionalString metricsTls "s"}://127.0.0.1:${toString metricsCfg.grafanaPort}";
                    passwordFile = "/var/lib/grafana/admin_password";
                  };
                };
              in
              {
                services.nginx = {
                  enable = mkDefault true;
                  virtualHosts.${webCfg.hostName} = {
                    root = import ./web.nix {
                      inherit pkgs lib;
                      servers = enabledWebServers;
                      domainSuffix = webDomainSuffix;
                      dashboardUrl = webCfg.dashboardUrl;
                    };
                    enableACME = webCfg.enableACME;
                    forceSSL = webCfg.enableACME;
                    # Live status + pack icons live in the poller's state dir,
                    # served alongside the static store index.html.
                    locations."= /status.json" = {
                      alias = "/var/lib/minecraft-web/status.json";
                      extraConfig = ''
                        add_header Cache-Control "no-store";
                        default_type application/json;
                      '';
                    };
                    locations."/icons/" = {
                      alias = "/var/lib/minecraft-web/icons/";
                    };
                  };
                };

                # One poller for the whole host refreshes a single cached
                # status.json; every visitor's browser just reads that file.
                systemd.services.minecraft-web-status = {
                  description = "Poll Minecraft servers for the modpack listing site";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network.target" ];
                  environment.SPARK_PARSER = "${./spark-report.py}";
                  serviceConfig = {
                    # NOT DynamicUser: that hides the state dir under
                    # /var/lib/private (0700), which nginx can't traverse ->
                    # 403 on /status.json and /icons/.
                    User = "minecraft-web";
                    Group = "minecraft-web";
                    StateDirectory = "minecraft-web";
                    Restart = "always";
                    RestartSec = "10s";
                    ExecStart = "${pkgs.python3}/bin/python3 ${./web-status.py} ${statusConfig}";
                  };
                };
                users.users.minecraft-web = {
                  isSystemUser = true;
                  group = "minecraft-web";
                  # minecraft-admin so the poller can move saved .sparkprofile
                  # files out of the server directories (2770 dirs).
                  extraGroups = optionals (cfg != { }) [ "minecraft-admin" ];
                };
                users.groups.minecraft-web = { };

                # Captured spark profiles, served like the dashboard: TLS from
                # the tailscale host cert, port admitted only on the metrics
                # module's exposeInterfaces (tailnet-only in the standard setup).
                services.nginx.virtualHosts."minecraft-spark-reports" = mkIf anySparkOnLag (
                  {
                    serverName =
                      if metricsCfg.enable && metricsCfg.grafanaDomain != null then
                        metricsCfg.grafanaDomain
                      else
                        "_";
                    listen = [
                      {
                        addr = "0.0.0.0";
                        port = webCfg.sparkReportsPort;
                        ssl = metricsTls;
                      }
                    ];
                    root = "/var/lib/minecraft-web/spark-reports";
                    locations."/".extraConfig = "autoindex on;";
                  }
                  // optionalAttrs metricsTls {
                    onlySSL = true;
                    sslCertificate = metricsCfg.tlsCertFile;
                    sslCertificateKey = metricsCfg.tlsKeyFile;
                  }
                );
                systemd.tmpfiles.rules = mkIf anySparkOnLag [
                  "d /var/lib/minecraft-web/spark-reports 0755 minecraft-web minecraft-web -"
                ];
                networking.firewall.interfaces = mkIf (anySparkOnLag && metricsCfg.enable) (
                  genAttrs metricsCfg.exposeInterfaces (_: {
                    allowedTCPPorts = [ webCfg.sparkReportsPort ];
                  })
                );

                # Lag-spike spark reports collected by the poller.
                environment.systemPackages = mkIf anySparkOnLag [
                  (pkgs.writeShellApplication {
                    name = "mc-lag-reports";
                    runtimeInputs = [
                      pkgs.jq
                      pkgs.util-linux
                    ];
                    text = ''
                      file=/var/lib/minecraft-web/lag-reports.jsonl
                      if [ ! -s "$file" ]; then
                        echo "no lag reports captured yet"
                        exit 0
                      fi
                      jq -rs '
                        (["WHEN","SERVER","TPS","REPORT"],
                         (.[] | [(.timestamp | split("+")[0]), .server, (.tps|tostring), (.url // ("<no url: " + (.response // "?") + ">"))]))
                        | @tsv' "$file" | column -t
                    '';
                  })
                ];

                networking.firewall.allowedTCPPorts = [
                  80
                  443
                ];
              }
            ))
            (mkIf metricsCfg.enable (
              let
                # Same rule as the status poller: implicit exporter port when
                # exportPrometheus is on, else an explicit metricsPort.
                scrapePortOf =
                  s:
                  if s.exportPrometheus then
                    (if s.metricsPort != null then s.metricsPort else 19565)
                  else
                    s.metricsPort;
                scrapedServers = filterAttrs (_: s: s.enable && scrapePortOf s != null) cfg;
                datasourceUid = "mc-prom";
                dashboard = import ./grafana-dashboard.nix { inherit datasourceUid; };
                dashboardDir = pkgs.writeTextDir "minecraft.json" (builtins.toJSON dashboard);
              in
              {
                services.prometheus = {
                  enable = true;
                  listenAddress = "127.0.0.1";
                  port = metricsCfg.prometheusPort;
                  globalConfig.scrape_interval = "15s";
                  scrapeConfigs = [
                    {
                      job_name = "minecraft";
                      static_configs = mapAttrsToList (name: s: {
                        targets = [ "127.0.0.1:${toString (scrapePortOf s)}" ];
                        labels.server = name;
                      }) scrapedServers;
                    }
                  ];
                };

                # Reachability is decided by the firewall: with
                # exposeInterfaces = [ "tailscale0" ] only tailnet peers your
                # ACLs admit can connect (plus loopback); everything else is
                # default-denied. Same pattern as the moonlight-web relay.
                services.grafana = {
                  enable = true;
                  settings = {
                    server =
                      let
                        useTls = metricsCfg.tlsCertFile != null && metricsCfg.tlsKeyFile != null;
                        scheme = if useTls then "https" else "http";
                      in
                      {
                        http_addr = if metricsCfg.exposeInterfaces == [ ] then "127.0.0.1" else "0.0.0.0";
                        http_port = metricsCfg.grafanaPort;
                      }
                      // optionalAttrs useTls {
                        protocol = "https";
                        cert_file = metricsCfg.tlsCertFile;
                        cert_key = metricsCfg.tlsKeyFile;
                      }
                      // optionalAttrs (metricsCfg.grafanaDomain != null) {
                        domain = metricsCfg.grafanaDomain;
                        root_url = "${scheme}://${metricsCfg.grafanaDomain}:${toString metricsCfg.grafanaPort}/";
                      };
                    # Anyone who can reach it may view; tailnet ACLs are the
                    # access control. Editing still needs the admin login.
                    "auth.anonymous" = {
                      enabled = true;
                      org_role = "Viewer";
                    };
                    analytics.reporting_enabled = false;
                    # 26.05 dropped the default secret_key; generated on the
                    # host at first start (preStart below), never in the store.
                    # The admin password is generated the same way — the NixOS
                    # default is admin/admin, which would let any ACL-admitted
                    # viewer take over the instance. Read it on the host:
                    #   cat /var/lib/grafana/admin_password
                    security = {
                      secret_key = "$__file{/var/lib/grafana/secret_key}";
                      admin_password = "$__file{/var/lib/grafana/admin_password}";
                    };
                  };
                  provision = {
                    enable = true;
                    datasources.settings.datasources = [
                      {
                        name = "Prometheus";
                        type = "prometheus";
                        uid = datasourceUid;
                        url = "http://127.0.0.1:${toString metricsCfg.prometheusPort}";
                        isDefault = true;
                      }
                    ];
                    dashboards.settings.providers = [
                      {
                        name = "minecraft";
                        options.path = dashboardDir;
                      }
                    ];
                  };
                };

                networking.firewall.interfaces = genAttrs metricsCfg.exposeInterfaces (_: {
                  allowedTCPPorts = [ metricsCfg.grafanaPort ];
                });

                # Runs as the grafana user, so the key lands 0600 in its own
                # state dir. head reads a finite amount first — no SIGPIPE.
                systemd.services.grafana.preStart = ''
                  umask 077
                  for f in secret_key admin_password; do
                    if [ ! -s "/var/lib/grafana/$f" ]; then
                      printf '%s' "$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)" > "/var/lib/grafana/$f"
                    fi
                  done
                  ${optionalString webCfg.enable ''
                    # The status poller posts lag-report annotations with this.
                    chgrp minecraft-web /var/lib/grafana/admin_password
                    chmod 640 /var/lib/grafana/admin_password
                  ''}
                '';
                users.users.grafana.extraGroups = optionals webCfg.enable [ "minecraft-web" ];
              }
            ))
            (mkIf routerCfg.enable (
              let
                mcRouter = import ./mc-router.nix { inherit pkgs; };
                enabledServers = filterAttrs (_: s: s.enable) cfg;
                speaksProxyProtocol =
                  s:
                  if s.acceptsProxyProtocol != null then
                    s.acceptsProxyProtocol
                  else
                    elem s.loader [
                      "paper"
                      "folia"
                    ];
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
                defaultArg =
                  optionalString (routerCfg.defaultServer != null)
                    " -default 127.0.0.1:${toString (backendPort cfg.${routerCfg.defaultServer})}";
                proxyArg = optionalString routerCfg.proxyProtocol " -use-proxy-protocol";
                loginLogPort = 25580;
                loginLogFile = "/var/lib/minecraft-login-log/logins.jsonl";
                loginArgs = optionalString routerCfg.recordLogins " -webhook-url http://127.0.0.1:${toString loginLogPort}/ -webhook-require-user";
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
                      ExecStart = "${mcRouter}/bin/mc-router -port ${toString routerCfg.port} -mapping ${escapeShellArg mappings}${proxyArg}${defaultArg}${loginArgs}";
                    };
                  };
                }
                // optionalAttrs routerCfg.recordLogins {
                  minecraft-login-log = {
                    description = "Persistent player connection log (mc-router webhook sink)";
                    wantedBy = [ "multi-user.target" ];
                    before = [ "mc-router.service" ];
                    serviceConfig = {
                      User = "minecraft";
                      Group = "minecraft-admin";
                      StateDirectory = "minecraft-login-log";
                      StateDirectoryMode = "0750";
                      UMask = "0027"; # logins.jsonl lands 640 minecraft:minecraft-admin
                      Restart = "always";
                      RestartSec = "5s";
                      ExecStart = "${pkgs.python3}/bin/python3 ${./login-log.py} ${toString loginLogPort} ${loginLogFile}";
                    };
                  };
                }
                // mapAttrs' (
                  name: s:
                  nameValuePair "mc-router-strip-${name}" {
                    description = "PROXY protocol stripper for Minecraft server ${name}";
                    wantedBy = [ "multi-user.target" ];
                    after = [ "network.target" ];
                    serviceConfig = {
                      DynamicUser = true;
                      Restart = "always";
                      RestartSec = "5s";
                      ExecStart = "${mcRouter}/bin/mc-router -port ${
                        toString (s.port + stripPortOffset)
                      } -receive-proxy-protocol -trusted-proxies 127.0.0.1/32 -default 127.0.0.1:${toString s.port}";
                    };
                  }
                ) (filterAttrs (_: s: needsStripper s) enabledServers);
                networking.firewall.allowedTCPPorts = mkIf routerCfg.openFirewall [ routerCfg.port ];

                # Summarise who connected from where (unique player/IP pairs,
                # counts, first/last seen). `mc-logins --raw` = full stream.
                environment.systemPackages = mkIf routerCfg.recordLogins [
                  (pkgs.writeShellApplication {
                    name = "mc-logins";
                    runtimeInputs = [
                      pkgs.jq
                      pkgs.util-linux
                    ];
                    text = ''
                      file=${loginLogFile}
                      if [ "''${1:-}" = "--raw" ]; then
                        exec cat "$file"
                      fi
                      jq -rs '
                        map(select(.event == "connected"))
                        | group_by([.player, .ip])
                        | map({player: .[0].player, ip: .[0].ip,
                               connections: length,
                               first: (map(.timestamp) | min | split(".")[0]),
                               last: (map(.timestamp) | max | split(".")[0]),
                               servers: (map(.server) | map(sub("\\..*$"; "")) | unique | join(","))})
                        | sort_by(.last) | reverse
                        | (["PLAYER","IP","N","FIRST","LAST","SERVERS"],
                           (.[] | [.player, .ip, (.connections|tostring), .first, .last, .servers]))
                        | @tsv' "$file" | column -t
                    '';
                  })
                ];
              }
            ))
            (mkIf (cfg != { }) (
              let
                # Runs as the minecraft user (via the scoped sudo rule below) and
                # emits a tar stream of the log files an agent needs for
                # debugging, keeping them as separate files.
                dumpScripts = mapAttrs (
                  name: _:
                  pkgs.writeShellScriptBin "dump-minecraft-logs-${name}" ''
                    dir=/srv/minecraft/${name}
                    tmp=$(${pkgs.coreutils}/bin/mktemp -d)
                    trap '${pkgs.coreutils}/bin/rm -rf "$tmp"' EXIT
                    cp "$dir/console.log" "$tmp/" 2>/dev/null
                    cp "$dir/logs/latest.log" "$tmp/" 2>/dev/null
                    mkdir -p "$tmp/crash-reports"
                    ls -t "$dir/crash-reports" 2>/dev/null | head -3 | while read -r f; do
                      cp "$dir/crash-reports/$f" "$tmp/crash-reports/" 2>/dev/null
                    done
                    ${pkgs.gnutar}/bin/tar -C "$tmp" -cf - .
                  ''
                ) (filterAttrs (_: s: s.enable) cfg);
              in
              {
                assertions = [
                  {
                    assertion = !(any (s: s.enable && s.sparkOnLag) (attrValues cfg)) || webCfg.enable;
                    message = "sparkOnLag needs services.minecraft-web enabled — its status poller is what watches TPS and runs the profiles.";
                  }
                ];

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
                        options = [
                          "NOPASSWD"
                          "SETENV"
                        ];
                      }
                    ]
                    ++ (mapAttrsToList (name: script: {
                      command = "${script}/bin/dump-minecraft-logs-${name}";
                      options = [ "NOPASSWD" ];
                    }) dumpScripts);
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
                    # The cpburnz Prometheus Exporter mod covers these loaders.
                    promLoader = elem serverCfg.loader [
                      "forge"
                      "fabric"
                      "neoforge"
                    ];
                    effMetricsPort = if serverCfg.metricsPort != null then serverCfg.metricsPort else 19565;
                    # Forge/Fabric read server configs from world/serverconfig;
                    # NeoForge from config/.
                    exporterCfgPath =
                      if serverCfg.loader == "neoforge" then
                        "${serverDir}/config/prometheus_exporter-server.toml"
                      else
                        "${serverDir}/world/serverconfig/prometheus_exporter-server.toml";
                    # Bind to loopback so only the local status poller can scrape it.
                    exporterCfg = pkgs.writeText "prometheus_exporter-server.toml" ''
                      [collector]
                      jvm = true
                      mc = true
                      mc_dimension_tick_errors = "LOG"
                      mc_entities = true
                      [web]
                      listen_address = "127.0.0.1"
                      listen_port = ${toString effMetricsPort}
                    '';
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

                    # Don't let a `switch` kick players off a running server: the
                    # new unit is put in place but only takes effect on the next
                    # natural restart (reboot / `systemctl restart minecraft-<name>`).
                    restartIfChanged = false;
                    stopIfChanged = false;

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

                      ${optionalString serverCfg.exportPrometheus (
                        if !promLoader then
                          ''
                            echo "prometheus-exporter: exportPrometheus is set but no exporter distributed on a trusted platform exists for loader '${serverCfg.loader}' — TPS will be unavailable." >&2
                          ''
                        else
                          ''
                            # --- Prometheus Exporter mod config (${serverCfg.loader}) ---
                            # The mod jar itself must come from the modpack, i.e. a
                            # trusted platform (`packwiz curseforge add
                            # prometheus-exporter`, side=server) — jars are never
                            # downloaded ad hoc here. This block only manages its
                            # config: bind to loopback on our port so just the local
                            # status poller / Prometheus can scrape it.
                            if ! ls ${serverDir}/mods/*[Pp]rometheus*[Ee]xporter*.jar >/dev/null 2>&1; then
                              echo "prometheus-exporter: not present in mods/ — add it to the modpack from CurseForge (packwiz curseforge add prometheus-exporter, side=server). TPS will be unavailable until then." >&2
                            fi
                            mkdir -p "$(dirname ${exporterCfgPath})"
                            cp -f ${exporterCfg} ${exporterCfgPath}
                            chmod u+w ${exporterCfgPath}
                          ''
                      )}

                      # The port option is authoritative: the router maps to it, so the
                      # server must actually bind it, whatever server.properties says.
                      if [ -f ${serverDir}/server.properties ] && grep -q '^server-port=' ${serverDir}/server.properties; then
                        sed -i 's/^server-port=.*/server-port=${toString serverCfg.port}/' ${serverDir}/server.properties
                      else
                        echo 'server-port=${toString serverCfg.port}' >> ${serverDir}/server.properties
                      fi

                      ${optionalString serverCfg.sparkOnLag (
                        optionalString
                          (elem serverCfg.loader [
                            "forge"
                            "fabric"
                            "neoforge"
                          ])
                          ''
                            # --- spark overlay (for the lag auto-profiler) ---
                            # Installed on top of the pack like the Prometheus
                            # Exporter config: fetched at most once, from spark's
                            # official Modrinth listing (trusted platform), with
                            # the API's sha512 verified. Paper/folia need nothing:
                            # spark ships inside the server since 1.21.
                            mods_dir=${serverDir}/mods
                            mkdir -p "$mods_dir"
                            if ls "$mods_dir"/spark-*.jar >/dev/null 2>&1; then
                              echo "spark: already present, leaving it in place."
                            else
                              echo "spark: fetching the ${serverCfg.minecraftVersion}/${serverCfg.loader} build from Modrinth..."
                              ver_json=$(curl -fsSL 'https://api.modrinth.com/v2/project/spark/version?loaders=%5B%22${serverCfg.loader}%22%5D&game_versions=%5B%22${serverCfg.minecraftVersion}%22%5D' || true)
                              url=$(printf '%s' "$ver_json" | ${pkgs.jq}/bin/jq -r 'first(.[0].files[] | select(.primary)) | .url // empty')
                              sha512=$(printf '%s' "$ver_json" | ${pkgs.jq}/bin/jq -r 'first(.[0].files[] | select(.primary)) | .hashes.sha512 // empty')
                              if [ -n "$url" ] && [ -n "$sha512" ]; then
                                if curl -fsSL "$url" -o "$mods_dir/spark-managed.jar" \
                                  && echo "$sha512  $mods_dir/spark-managed.jar" | sha512sum -c --quiet -; then
                                  echo "spark: installed from $url"
                                else
                                  echo "spark: download or checksum FAILED — lag auto-profiling will be unavailable." >&2
                                  rm -f "$mods_dir/spark-managed.jar"
                                fi
                              else
                                echo "spark: no Modrinth build for ${serverCfg.minecraftVersion}/${serverCfg.loader} — lag auto-profiling will be unavailable." >&2
                              fi
                            fi
                          ''
                      )}

                      ${optionalString serverCfg.sparkOnLag ''
                        # --- RCON for the lag auto-profiler ---
                        # Loopback only in practice: the firewall never opens the
                        # rcon port. preStart runs as the minecraft user, so the
                        # directory comes from tmpfiles (setgid minecraft-web:
                        # the password file inherits the group the status poller
                        # reads with; umask 037 makes it 640).
                        if [ ! -s /var/lib/minecraft-rcon/${name} ]; then
                          (umask 037; head -c 24 /dev/urandom | base64 | tr -d '/+=\n' > /var/lib/minecraft-rcon/${name})
                        fi
                        rcon_pw=$(cat /var/lib/minecraft-rcon/${name})
                        for kv in 'enable-rcon=true' 'rcon.port=${toString (serverCfg.port + rconPortOffset)}' "rcon.password=$rcon_pw" 'broadcast-rcon-to-ops=false'; do
                          key=''${kv%%=*}
                          if grep -q "^$key=" ${serverDir}/server.properties; then
                            sed -i "s|^$key=.*|$kv|" ${serverDir}/server.properties
                          else
                            echo "$kv" >> ${serverDir}/server.properties
                          fi
                        done
                      ''}

                      # Behind the router with PROXY protocol on, Paper-family
                      # servers must accept the header or every connection fails.
                      ${optionalString
                        (
                          routerCfg.enable
                          && routerCfg.proxyProtocol
                          && elem serverCfg.loader [
                            "paper"
                            "folia"
                          ]
                        )
                        ''
                          mkdir -p ${serverDir}/config
                          if grep -q 'proxy-protocol:' ${serverDir}/config/paper-global.yml 2>/dev/null; then
                            sed -i 's/proxy-protocol: false/proxy-protocol: true/' ${serverDir}/config/paper-global.yml
                          else
                            printf 'proxies:\n  proxy-protocol: true\n' >> ${serverDir}/config/paper-global.yml
                          fi
                        ''
                      }
                    '';

                    script =
                      let
                        cmd = meta.launchCmd {
                          inherit (serverCfg) javaPackage ramGb;
                          inherit serverDir;
                          jvmFlags = import ./jvm-flags.nix {
                            inherit lib;
                            inherit (serverCfg) ramGb;
                            aikar = serverCfg.aikarFlags;
                          };
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
                  ++ optionals (webCfg.enable && any (s: s.enable && s.sparkOnLag) (attrValues cfg)) [
                    # setgid: rcon passwords created inside inherit minecraft-web
                    # so the status poller can read them (files land 640).
                    "d /var/lib/minecraft-rcon 2750 minecraft minecraft-web -"
                  ]
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
                  ) (filterAttrs (_: s: s.enable) cfg))
                  ++ (mapAttrsToList (
                    name: script:
                    # Streams a tar of journal + server logs + crash reports to
                    # stdout (separate files inside), so it works locally and
                    # over ssh alike:
                    #   ssh <host> logs-<name> | tar -xC /tmp/minecraft-<name>-logs
                    pkgs.writeShellScriptBin "logs-${name}" ''
                      set -e
                      tmp=$(mktemp -d)
                      trap 'rm -rf "$tmp"' EXIT
                      journalctl -u minecraft-${name} -n 300 --no-pager > "$tmp/journal.log" 2>&1 \
                        || echo "(journal unavailable to this user)" > "$tmp/journal.log"
                      sudo -u minecraft ${script}/bin/dump-minecraft-logs-${name} \
                        | ${pkgs.gnutar}/bin/tar -xC "$tmp"
                      if [ -t 1 ]; then
                        # Interactive use: unpack to /tmp like mc-logs does locally.
                        out=/tmp/minecraft-${name}-logs
                        rm -rf "$out"
                        mkdir -p "$out"
                        cp -r "$tmp"/. "$out"/
                        echo "$out"
                        ls "$out" "$out/crash-reports" 2>/dev/null
                      else
                        ${pkgs.gnutar}/bin/tar -C "$tmp" -cf - .
                      fi
                    ''
                  ) dumpScripts);
              }
            ))
          ];
        };

      # Local-side companion to the module's logs-<name> command: pulls the
      # log bundle from a remote server host and unpacks it under /tmp so an
      # agent can grep the individual files.
      #   mc-logs <server-name> [host]   (host defaults to glados)
      packages.x86_64-linux.mc-logs = pkgs.writeShellScriptBin "mc-logs" ''
        set -e
        name=$1
        host=''${2:-glados}
        if [ -z "$name" ]; then
          echo "usage: mc-logs <server-name> [host]" >&2
          exit 1
        fi
        out=/tmp/minecraft-$name-logs
        rm -rf "$out"
        mkdir -p "$out"
        ssh "$host" "logs-$name" | ${pkgs.gnutar}/bin/tar -xC "$out"
        echo "$out"
        ls "$out" "$out/crash-reports" 2>/dev/null
      '';

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
