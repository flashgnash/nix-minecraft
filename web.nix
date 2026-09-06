# Generates the static modpack listing site served by services.minecraft-web.
#
# One card per enabled server, derived from the module config. Client packs
# (forge/neoforge/fabric) get a big drag-into-Prism pack icon, a launcher-aware
# primary download and an "other launchers" section; server-only loaders
# (paper/folia) need no client install and just show the join address.
#
# Live MOTD / player count / TPS are NOT baked in here — the page fetches the
# cached /status.json that the host's single status poller refreshes, so every
# visitor reads one shared file instead of hammering the servers.
#
# House visual style (see STYLE.md in the nixos-configuration repo): dark teal
# surfaces, one lime accent, full-width accent-underline tabs, ComicShannsMono
# with a monospace fallback (visitors won't have the font installed) and no
# nerd-font glyphs (they'd render as boxes) — a drawn SVG is used instead.
{
  pkgs,
  lib,
  servers,
  domainSuffix,
}:
with lib;
let
  # https://raw.githubusercontent.com/<owner>/<repo>/... -> [ owner repo ]
  githubRepo = url: match "https://raw\\.githubusercontent\\.com/([^/]+)/([^/]+)/.*" url;
  isClient =
    loader:
    elem loader [
      "forge"
      "neoforge"
      "fabric"
    ];

  # Rolling-release artifacts published by the packwiz-tui CI under
  # releases/latest as <repo><file>.
  artifacts = {
    prism = {
      label = "Prism";
      file = "-prism.zip";
      desc = "Self-updating PrismLauncher instance (small download, fetches mods on first launch)";
    };
    preinstalled = {
      label = "Prism (preinstalled)";
      file = "-prism-preinstalled.zip";
      desc = "PrismLauncher instance with every mod bundled (large download, instant first launch)";
    };
    mrpack = {
      label = ".mrpack";
      file = ".mrpack";
      desc = "Modrinth format — opens in the Modrinth App, or drag it onto Prism";
    };
    curseforge = {
      label = "CurseForge";
      file = "-curseforge.zip";
      desc = "Import into the CurseForge launcher";
    };
  };

  # Each top-of-page launcher tab reshapes every client card's hero + the
  # "other launchers" list. Default (no cookie) is Prism.
  launchers = [
    {
      key = "prism";
      primary = "prism";
      heroTitle = "Drag &amp; drop into Prism to install";
      heroBtn = "Download for Prism";
      others = [
        "preinstalled"
        "mrpack"
        "curseforge"
      ];
    }
    {
      key = "mrpack";
      primary = "mrpack";
      heroTitle = "Open with the Modrinth App — or drag onto Prism";
      heroBtn = "Download .mrpack";
      others = [
        "prism"
        "preinstalled"
        "curseforge"
      ];
    }
    {
      key = "curseforge";
      primary = "curseforge";
      heroTitle = "Import into the CurseForge app";
      heroBtn = "Download for CurseForge";
      others = [
        "prism"
        "preinstalled"
        "mrpack"
      ];
    }
  ];

  # Card icon precedence (applied client-side): the server-icon.png (favicon
  # from the ping) first, then the pack icon, and finally the mod loader's own
  # emblem below. Drawn as SVG so it renders without the nerd font.
  loaderSvg =
    body:
    ''<svg class="pack-icon-glyph" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">${body}</svg>'';
  anvil =
    fill:
    ''<path fill="${fill}" d="M2 7h8v2c2 0 3.3 .8 4.3 2l3.4-1.4 .9 1.9-3.1 1.4c.1 .5 .1 1 .1 1.5H6c0-2.6 1.6-4 3.2-4.7H5V13H2z"/><rect x="7" y="18" width="10" height="2.2" rx=".5" fill="${fill}"/>'';
  loaderIcons = {
    forge = loaderSvg (anvil "#8a9bb0");
    neoforge = loaderSvg (anvil "#f2842b");
    fabric = loaderSvg ''<g fill="none" stroke="#c9a37a" stroke-width="2.6" stroke-linecap="round"><path d="M5 8h14M5 12h14M5 16h14"/></g>'';
    paper = loaderSvg ''<path fill="#cfd8dc" d="M7 3h7l4 4v14H7z"/><path fill="#8fa0a8" d="M14 3l4 4h-4z"/>'';
    folia = loaderSvg ''<path fill="#63b356" d="M20 4C9 4 4 9 4 20c9 0 16-4 16-16z"/><path fill="none" stroke="#38792f" stroke-width="1.3" d="M7 18c4-5 8-8 11-10"/>'';
  };
  loaderIcon =
    loader:
    loaderIcons.${loader}
      or (loaderSvg ''<path fill="none" stroke="#9dff00" stroke-width="1.4" stroke-linejoin="round" d="M12 2 3 7v10l9 5 9-5V7z"/><path fill="none" stroke="#9dff00" stroke-width="1.4" d="M3 7l9 5 9-5M12 12v10"/>'');

  serverCard =
    name: s:
    let
      repo = githubRepo s.packwizUrl;
      dlKey =
        k:
        "https://github.com/${elemAt repo 0}/${elemAt repo 1}/releases/latest/download/${elemAt repo 1}${artifacts.${k}.file}";
      address = if domainSuffix != null then "${name}.${domainSuffix}" else null;
      client = isClient s.loader;

      otherBtn =
        k: ''<a class="btn" href="${dlKey k}" title="${artifacts.${k}.desc}">${artifacts.${k}.label}</a>'';

      heroBlock = l: ''
        <div class="lv lv-${l.key}">
          <a class="pack-hero" href="${dlKey l.primary}" title="Download this pack">
            <span class="pack-icon">
              <img class="pack-icon-img" alt="" />
              ${loaderIcon s.loader}
            </span>
          </a>
          <div class="hero-text">
            <div class="hero-title">${l.heroTitle}</div>
            <a class="btn primary" href="${dlKey l.primary}">${l.heroBtn}</a>
            <div class="hero-hint">Once downloaded, drag the file onto your launcher window.</div>
          </div>
          <div class="others">
            <div class="others-label">Other launchers</div>
            <div class="others-btns">
              ${concatMapStringsSep "\n" otherBtn l.others}
            </div>
          </div>
        </div>
      '';

      addressRow =
        if address != null then
          ''
            <p class="row">server address
              <code class="copy" onclick="selectText(this)" title="click to select, then copy">${address}</code>
            </p>
          ''
        else
          ''
            <p class="row muted">server address not configured (enable the router)</p>
          '';

      body =
        if !client then
          ''
            <p class="server-note">Server-side pack — no client modpack to install. Add the address below in your multiplayer list and join.</p>
          ''
        else if repo == null then
          ''
            <div class="muted">No release artifacts configured for this pack.</div>
          ''
        else
          concatMapStringsSep "\n" heroBlock launchers;
    in
    ''
      <section class="card${optionalString (!client) " server-only"}" data-name="${name}">
        <div class="card-head">
          ${optionalString (
            !client
          ) ''<span class="mini-icon"><img class="pack-icon-img" alt="" />${loaderIcon s.loader}</span>''}
          <h2>${name}</h2>
          <div class="chips">
            <span class="chip">${s.loader}</span>
            <span class="chip">${s.minecraftVersion}</span>
            ${optionalString (!client) ''<span class="chip chip-alt">server only</span>''}
            <span class="status-dot" title="server status"></span>
          </div>
        </div>
        <div class="stats" data-status="${name}">
          <span class="stat motd" data-k="motd"></span>
          <span class="stat"><b data-k="players">—</b> online</span>
          <span class="stat">TPS <b class="tps-val" data-k="tps">—</b></span>
        </div>
        ${body}
        ${addressRow}
      </section>
    '';

  html = ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Modpacks</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #192227;
        --panel: #263238;
        --inset: #11181c;
        --hover: #314048;
        --border: #3a4a52;
        --text: #ffffff;
        --dim: rgba(255,255,255,0.55);
        --accent: #9dff00;
        --accent-dark: #8db946;
        --warning: #cc7a00;
        --critical: #bf616a;
        --font: "ComicShannsMono Nerd Font", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
      }
      * { box-sizing: border-box; }
      body {
        font-family: var(--font);
        background: var(--bg);
        color: var(--text);
        max-width: 780px;
        margin: 0 auto;
        padding: 2rem 1rem 4rem;
        line-height: 1.5;
      }
      header h1 { font-weight: 700; margin: 0; font-size: 1.9rem; }
      header .sub { color: var(--dim); margin: .25rem 0 0; font-size: .9rem; }

      /* Tabs — full-width accent underline (house style) */
      .tabs { display: flex; margin: 1.5rem 0 .5rem; border-bottom: 1px solid var(--border); }
      .tab {
        flex: 1 1 0; text-align: center; cursor: pointer; user-select: none;
        background: none; border: 0; color: var(--dim); font: inherit;
        padding: .55rem .2rem calc(.55rem - 3px); font-size: 1rem;
        border-bottom: 3px solid transparent; transition: color .08s, border-color .08s;
      }
      .tab:hover { color: var(--text); border-bottom-color: var(--accent-dark); }
      .tab.active { color: var(--accent); font-weight: 700; border-bottom-color: var(--accent); }

      /* Cards */
      .card {
        background: var(--panel); border: 1px solid var(--border); border-radius: 8px;
        padding: 1rem 1.25rem 1.15rem; margin: 1rem 0;
      }
      .card.offline { opacity: .82; }
      .card-head { display: flex; align-items: center; gap: .75rem; flex-wrap: wrap; }
      .card-head h2 { margin: 0; font-size: 1.25rem; flex: 1 1 auto; }
      .chips { display: flex; align-items: center; gap: .4rem; flex-wrap: wrap; }
      .chip {
        background: var(--inset); border: 1px solid var(--border); border-radius: 999px;
        padding: .12rem .6rem; font-size: .78rem; color: var(--dim);
      }
      .chip-alt { color: var(--accent-dark); border-color: var(--accent-dark); }
      .status-dot {
        width: 9px; height: 9px; border-radius: 999px; background: var(--dim);
        transition: background .12s;
      }
      .card.online .status-dot { background: var(--accent); box-shadow: 0 0 6px var(--accent); }
      .card.offline .status-dot { background: var(--critical); box-shadow: none; }

      /* Live stats row */
      .stats {
        display: flex; align-items: baseline; gap: .35rem 1.1rem; flex-wrap: wrap;
        margin: .6rem 0 .2rem; font-size: .85rem; color: var(--dim); min-height: 1.2em;
      }
      .stats .motd { color: var(--text); flex-basis: 100%; font-size: .9rem; }
      .stats b { color: var(--text); font-weight: 700; }
      .tps-val.ok { color: var(--accent); }
      .tps-val.warn { color: var(--warning); }
      .tps-val.crit { color: var(--critical); }

      /* Launcher variants: only the selected one shows */
      .lv { display: none; margin-top: .9rem; }
      body[data-launcher="prism"] .lv-prism,
      body[data-launcher="mrpack"] .lv-mrpack,
      body[data-launcher="curseforge"] .lv-curseforge { display: block; }

      /* Hero: big pack icon + primary action */
      .pack-hero { float: left; display: block; text-decoration: none; }
      .pack-icon {
        display: flex; align-items: center; justify-content: center;
        width: 104px; height: 104px; margin: 0 1.1rem .6rem 0;
        background: var(--inset); border: 1px solid var(--border); border-radius: 10px;
        color: var(--accent); transition: border-color .08s, background .08s; overflow: hidden;
      }
      .pack-hero:hover .pack-icon { border-color: var(--accent); background: #0d1418; }
      .pack-icon .pack-icon-glyph { width: 62px; height: 62px; }
      .pack-icon-img { display: none; width: 100%; height: 100%; object-fit: cover; }

      /* Small header avatar on server-only cards (server-icon / loader emblem) */
      .mini-icon {
        flex: 0 0 auto; width: 40px; height: 40px; display: flex;
        align-items: center; justify-content: center; overflow: hidden;
        background: var(--inset); border: 1px solid var(--border); border-radius: 8px;
      }
      .mini-icon .pack-icon-glyph { width: 26px; height: 26px; }
      .hero-text { overflow: hidden; }
      .hero-title { font-size: 1.05rem; font-weight: 700; margin-bottom: .55rem; }
      .hero-hint { color: var(--dim); font-size: .78rem; margin-top: .5rem; }

      .others { clear: both; padding-top: .9rem; margin-top: .3rem; border-top: 1px solid var(--border); }
      .others-label { color: var(--dim); font-size: .78rem; margin-bottom: .45rem; }
      .others-btns { display: flex; flex-wrap: wrap; gap: .5rem; }

      /* Buttons */
      .btn {
        display: inline-block; background: var(--panel); color: var(--text);
        text-decoration: none; padding: .45rem .9rem; border-radius: 5px;
        border: 1px solid var(--border); font-size: .88rem; cursor: pointer;
        transition: background .08s, border-color .08s;
      }
      .btn:hover { background: var(--hover); }
      .btn.primary {
        background: var(--accent); color: #12180b; border-color: var(--accent);
        font-weight: 700; padding: .55rem 1.1rem; font-size: .95rem;
      }
      .btn.primary:hover { background: var(--accent-dark); border-color: var(--accent-dark); }

      .row { font-size: .85rem; color: var(--dim); margin: .8rem 0 0; clear: both; }
      .row.muted, .muted { color: var(--dim); }
      .server-note { color: var(--dim); font-size: .9rem; margin: .9rem 0 0; }
      code.copy {
        background: var(--inset); padding: .2rem .5rem; border-radius: 6px;
        cursor: pointer; color: #c8d0dc; margin-left: .4rem;
      }
      code.copy:hover { background: #0d1418; }
      code.copy::selection { background: var(--accent); color: #12180b; }

      /* How to install */
      details.howto {
        margin-top: 2rem; background: var(--panel); border: 1px solid var(--border);
        border-radius: 8px; padding: .4rem 1.1rem; color: var(--dim); font-size: .9rem;
      }
      details.howto summary {
        cursor: pointer; color: var(--text); font-weight: 700; padding: .55rem 0;
        list-style: none;
      }
      details.howto summary::-webkit-details-marker { display: none; }
      details.howto summary::before { content: "▸ "; color: var(--accent); }
      details.howto[open] summary::before { content: "▾ "; }
      details.howto ol { margin: .2rem 0 .6rem; padding-left: 1.2rem; }
      details.howto li { margin: .3rem 0; }
      details.howto a { color: var(--accent); }
      details.howto code { background: var(--inset); padding: .1rem .4rem; border-radius: 4px; }
    </style>
    </head>
    <body data-launcher="prism">
    <header>
      <h1>Modpacks</h1>
      <p class="sub">Pick your launcher, grab a pack, and join the server.</p>
    </header>

    <div class="tabs" role="tablist">
      <button class="tab" data-launcher="prism">Prism</button>
      <button class="tab" data-launcher="mrpack">.mrpack</button>
      <button class="tab" data-launcher="curseforge">CurseForge</button>
    </div>

    ${concatStringsSep "\n" (mapAttrsToList serverCard servers)}

    <details class="howto" open>
      <summary>How to install</summary>
      <ol>
        <li>Install <a href="https://prismlauncher.org/download/">PrismLauncher</a> (free, all platforms) — or the launcher you picked above.</li>
        <li>Click the big pack icon or <b>Download</b> to grab the pack file.</li>
        <li>In Prism: <b>Add Instance → Import → Browse</b> and pick the file — or just drag it onto the Prism window.</li>
        <li>Launch. The pack fetches its mods on first start and keeps itself updated every launch.</li>
      </ol>
      <p>Prefer the Modrinth App or CurseForge? Switch the tab at the top — the <code>.mrpack</code> and CurseForge zips import into those launchers instead (these don't self-update). Copy the server address from a card to join.</p>
    </details>

    <script>
      // Select-on-click only — no clipboard API, which ad blockers
      // (rightly) treat as a ClickFix-attack signature.
      function selectText(el) {
        var range = document.createRange();
        range.selectNodeContents(el);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }

      var LAUNCHERS = ["prism", "mrpack", "curseforge"];
      function setCookie(k, v) { document.cookie = k + "=" + v + ";path=/;max-age=31536000;samesite=lax"; }
      function getCookie(k) {
        var m = document.cookie.match("(^|;)\\s*" + k + "\\s*=\\s*([^;]+)");
        return m ? m[2] : null;
      }
      function setLauncher(l) {
        if (LAUNCHERS.indexOf(l) < 0) l = "prism";
        document.body.dataset.launcher = l;
        var tabs = document.querySelectorAll(".tab");
        for (var i = 0; i < tabs.length; i++) {
          tabs[i].classList.toggle("active", tabs[i].dataset.launcher === l);
        }
        setCookie("launcher", l);
      }
      var tabEls = document.querySelectorAll(".tab");
      for (var t = 0; t < tabEls.length; t++) {
        tabEls[t].addEventListener("click", function () { setLauncher(this.dataset.launcher); });
      }
      setLauncher(getCookie("launcher") || "prism");

      // Live status: one shared cached file, refreshed by the host poller.
      function tpsClass(v) {
        if (v == null) return "";
        if (v >= 19) return "ok";
        if (v >= 15) return "warn";
        return "crit";
      }
      function loadStatus() {
        fetch("/status.json", { cache: "no-store" }).then(function (r) {
          return r.json();
        }).then(function (d) {
          (d.servers || []).forEach(function (s) {
            var box = document.querySelector('.card[data-name="' + s.name + '"]');
            if (!box) return;
            box.classList.toggle("online", !!s.online);
            box.classList.toggle("offline", !s.online);
            var motd = box.querySelector("[data-k=motd]");
            if (motd) motd.textContent = s.online ? (s.motd || "") : "Offline";
            var pl = box.querySelector("[data-k=players]");
            if (pl) {
              pl.textContent = (s.players_online == null ? "—" : s.players_online) +
                (s.players_max != null ? " / " + s.players_max : "");
            }
            var tps = box.querySelector("[data-k=tps]");
            if (tps) {
              tps.textContent = (s.tps == null ? "—" : s.tps.toFixed(1));
              tps.className = "tps-val " + tpsClass(s.tps);
            }
            // Icon precedence: server-icon (favicon) -> pack icon -> loader emblem.
            var src = s.favicon || (s.icon ? "/icons/" + s.icon : null);
            if (src) {
              var imgs = box.querySelectorAll(".pack-icon-img");
              for (var k = 0; k < imgs.length; k++) {
                (function (img) {
                  img.onload = function () {
                    img.style.display = "block";
                    var g = img.parentElement.querySelector(".pack-icon-glyph");
                    if (g) g.style.display = "none";
                  };
                  img.onerror = function () { img.style.display = "none"; };
                  img.src = src;
                })(imgs[k]);
              }
            }
          });
        }).catch(function () {});
      }
      loadStatus();
      setInterval(loadStatus, 15000);
    </script>
    </body>
    </html>
  '';
in
pkgs.writeTextDir "index.html" html
