# Provisioned Grafana dashboard for the cpburnz Prometheus Exporter metrics
# (see metrics.md in that repo: mc_server_tick_seconds / mc_dimension_tick_seconds
# histograms, mc_dimension_chunks_loaded, mc_entities_total, mc_player_list,
# plus the JVM client metrics).
#
# The exporter has no per-chunk data, so "what is lagging" is answered by the
# per-dimension tick share, entity counts by type, and loaded chunk counts.
#
# Returns the dashboard as a Nix attrset; the module serialises it with
# builtins.toJSON and drops it in Grafana's dashboard provisioning directory.
{ datasourceUid }:
let
  ds = {
    type = "prometheus";
    uid = datasourceUid;
  };

  # Every query is filtered to the dashboard's $server variable so multiple
  # servers on one host each get a clean view.
  sel = ''server=~"$server"'';

  ts = title: gridPos: unit: targets: extra: {
    type = "timeseries";
    inherit title gridPos targets;
    datasource = ds;
    fieldConfig = {
      defaults = {
        inherit unit;
        custom = {
          fillOpacity = 12;
          lineWidth = 2;
          showPoints = "never";
        } // (extra.custom or { });
      } // (extra.defaults or { });
      overrides = [ ];
    };
    options = {
      legend = {
        displayMode = "list";
        placement = "bottom";
      };
      tooltip = {
        mode = "multi";
        sort = "desc";
      };
    };
  };

  q = refId: expr: legendFormat: {
    inherit refId expr legendFormat;
    datasource = ds;
  };
in
{
  title = "Minecraft";
  uid = "minecraft";
  editable = true;
  schemaVersion = 39;
  refresh = "30s";
  time = {
    from = "now-1h";
    to = "now";
  };
  timezone = "browser";
  annotations.list = [ ];
  templating.list = [
    {
      name = "server";
      label = "server";
      type = "query";
      datasource = ds;
      # Enforced single pick: every panel is scoped to exactly one server
      # (the site's deep links preset it via ?var-server=<name>).
      query = "label_values(mc_server_tick_seconds_count, server)";
      refresh = 2;
      includeAll = false;
      multi = false;
    }
  ];
  panels = [
    (ts "TPS"
      {
        x = 0;
        y = 0;
        w = 12;
        h = 8;
      }
      "none"
      [ (q "A" ''clamp_max(rate(mc_server_tick_seconds_count{${sel}}[2m]), 20)'' "{{server}}") ]
      {
        defaults = {
          min = 0;
          max = 20;
        };
      }
    )
    (ts "Server tick duration"
      {
        x = 12;
        y = 0;
        w = 12;
        h = 8;
      }
      "ms"
      [
        (q "A"
          ''1000 * rate(mc_server_tick_seconds_sum{${sel}}[5m]) / rate(mc_server_tick_seconds_count{${sel}}[5m])''
          "{{server}} avg"
        )
        (q "B"
          ''1000 * histogram_quantile(0.95, sum by (le, server) (rate(mc_server_tick_seconds_bucket{${sel}}[5m])))''
          "{{server}} p95"
        )
      ]
      {
        # 50 ms/tick is the 20 TPS budget
        custom.thresholdsStyle.mode = "line";
        defaults.thresholds = {
          mode = "absolute";
          steps = [
            {
              color = "green";
              value = null;
            }
            {
              color = "red";
              value = 50;
            }
          ];
        };
      }
    )
    (ts "Tick time by dimension (lag source)"
      {
        x = 0;
        y = 8;
        w = 12;
        h = 8;
      }
      "ms"
      [
        (q "A"
          ''1000 * sum by (server, name) (rate(mc_dimension_tick_seconds_sum{${sel}}[5m])) / sum by (server, name) (rate(mc_dimension_tick_seconds_count{${sel}}[5m]))''
          "{{server}} {{name}}"
        )
      ]
      { }
    )
    (ts "Tick budget spent per dimension"
      {
        x = 12;
        y = 8;
        w = 12;
        h = 8;
      }
      "percent"
      [
        (q "A" ''100 * sum by (server, name) (rate(mc_dimension_tick_seconds_sum{${sel}}[5m]))''
          "{{server}} {{name}}"
        )
      ]
      { custom.stacking.mode = "normal"; }
    )
    (ts "Entities by type (top 15)"
      {
        x = 0;
        y = 16;
        w = 12;
        h = 9;
      }
      "none"
      [ (q "A" ''topk(15, sum by (type) (mc_entities_total{${sel}}))'' "{{type}}") ]
      { }
    )
    (ts "Entities by dimension"
      {
        x = 12;
        y = 16;
        w = 6;
        h = 9;
      }
      "none"
      [ (q "A" ''sum by (server, dim) (mc_entities_total{${sel}})'' "{{server}} {{dim}}") ]
      { }
    )
    (ts "Dropped items on the ground"
      {
        x = 18;
        y = 16;
        w = 6;
        h = 9;
      }
      "none"
      [ (q "A" ''sum by (server, dim) (mc_entities_total{type="Item", ${sel}})'' "{{server}} {{dim}}") ]
      { }
    )
    (ts "Chunks loaded by dimension"
      {
        x = 0;
        y = 25;
        w = 12;
        h = 8;
      }
      "none"
      [ (q "A" ''mc_dimension_chunks_loaded{${sel}}'' "{{server}} {{name}}") ]
      { }
    )
    (ts "Players online"
      {
        x = 12;
        y = 25;
        w = 6;
        h = 8;
      }
      "none"
      [ (q "A" ''count by (server) (mc_player_list{${sel}}) or vector(0)'' "{{server}}") ]
      { defaults.min = 0; }
    )
    {
      type = "table";
      title = "Who is on";
      gridPos = {
        x = 18;
        y = 25;
        w = 6;
        h = 8;
      };
      datasource = ds;
      targets = [
        {
          refId = "A";
          expr = ''mc_player_list{server=~"$server"}'';
          format = "table";
          instant = true;
          datasource = ds;
        }
      ];
      transformations = [
        {
          id = "organize";
          options = {
            excludeByName = {
              Time = true;
              Value = true;
              "__name__" = true;
              id = true;
              instance = true;
              job = true;
            };
          };
        }
      ];
      fieldConfig = {
        defaults = { };
        overrides = [ ];
      };
      options = { };
    }
    (ts "JVM heap"
      {
        x = 0;
        y = 33;
        w = 12;
        h = 8;
      }
      "bytes"
      [
        (q "A" ''jvm_memory_bytes_used{area="heap", ${sel}}'' "{{server}} used")
        (q "B" ''jvm_memory_bytes_max{area="heap", ${sel}}'' "{{server}} max")
      ]
      { }
    )
    (ts "GC time share"
      {
        x = 12;
        y = 33;
        w = 12;
        h = 8;
      }
      "percent"
      [
        (q "A" ''100 * sum by (server, gc) (rate(jvm_gc_collection_seconds_sum{${sel}}[5m]))''
          "{{server}} {{gc}}"
        )
      ]
      { }
    )
  ];
}
