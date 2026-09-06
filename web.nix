# Generates the static modpack listing site served by services.minecraft-web.
#
# One card per enabled server, derived from the module config. Client packs
# (forge/neoforge/fabric) get a big drag-into-Prism pack icon and a
# launcher-aware primary download; server-only loaders (paper/folia) need no
# client install and just show the join address.
#
# Live MOTD / player count / TPS are NOT baked in here — the page fetches the
# cached /status.json that the host's single status poller refreshes, so every
# visitor reads one shared file instead of hammering the servers.
#
# Platform icons are the real brand logos, vendored in ./web-assets (Forge /
# NeoForge / Fabric / Paper / Folia loader emblems, used as the pack-icon
# fallback when the server publishes no favicon).
#
# House visual style (see STYLE.md in the nixos-configuration repo): dark teal
# surfaces, one lime accent, full-width accent-underline tabs, ComicShannsMono
# with a monospace fallback (visitors won't have the font installed).
{
  pkgs,
  lib,
  servers,
  domainSuffix,
  # Grafana base URL; the link is revealed client-side only after a
  # reachability probe succeeds (it's typically tailnet-only).
  dashboardUrl ? null,
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
      desc = "Modrinth format — opens in the Modrinth App";
    };
    curseforge = {
      label = "CurseForge";
      file = "-curseforge.zip";
      desc = "Import into the CurseForge launcher";
    };
  };

  # Every client card carries its own launcher tab strip; picking a tab
  # switches all cards and the how-to section together (cookie-persisted,
  # default Prism). The cookie key for Modrinth stays "mrpack" for
  # compatibility with already-set cookies.
  launchers = [
    {
      key = "prism";
      label = "Prism";
      primary = "prism";
      secondary = "preinstalled";
      secondaryLabel = "Download for Prism (preloaded)";
      heroTitle = "Drag &amp; drop this card into Prism to install";
      heroBtn = "Download for Prism";
      heroHint = "Drag the card straight onto the Prism window — or download and drag the file.";
    }
    {
      key = "mrpack";
      label = "Modrinth";
      primary = "mrpack";
      heroTitle = "Open with the Modrinth App";
      heroBtn = "Download .mrpack";
      heroHint = "Once downloaded, open the file — the Modrinth App imports it.";
    }
    {
      key = "curseforge";
      label = "CurseForge";
      primary = "curseforge";
      heroTitle = "Import into the CurseForge app";
      heroBtn = "Download for CurseForge";
      heroHint = "Once downloaded, import the zip in the CurseForge app.";
    }
  ];

  tabStrip = ''
    <div class="tabs" role="tablist">
      ${concatMapStringsSep "\n" (
        l: ''<button class="tab" data-launcher="${l.key}">${l.label}</button>''
      ) launchers}
    </div>
  '';

  # The big icon inside each pack panel is the launcher's own logo — the
  # modpack's icon lives in the pack header above the tabs.
  launcherLogos = {
    prism = "prism.svg";
    mrpack = "modrinth.png";
    curseforge = "curseforge.png";
  };

  # Card icon precedence (applied client-side): the server-icon.png (favicon
  # from the ping) first, then the pack icon, then the loader's brand logo.
  loaderIconFiles = {
    forge = "forge.png";
    neoforge = "neoforge.png";
    fabric = "fabric.png";
    paper = "paper.svg";
    folia = "folia.svg";
  };
  loaderIcon =
    loader:
    if loaderIconFiles ? ${loader} then
      ''<img class="pack-icon-glyph" src="/assets/${loaderIconFiles.${loader}}" alt="${loader}" />''
    else
      ''<svg class="pack-icon-glyph" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path fill="none" stroke="#9dff00" stroke-width="1.4" stroke-linejoin="round" d="M12 2 3 7v10l9 5 9-5V7z"/><path fill="none" stroke="#9dff00" stroke-width="1.4" d="M3 7l9 5 9-5M12 12v10"/></svg>'';

  serverCard =
    name: s:
    let
      repo = githubRepo s.packwizUrl;
      dlKey =
        k:
        "https://github.com/${elemAt repo 0}/${elemAt repo 1}/releases/latest/download/${elemAt repo 1}${artifacts.${k}.file}";
      address = if domainSuffix != null then "${name}.${domainSuffix}" else null;
      client = isClient s.loader;

      # The whole pack panel is the drag target: dragging it out of the
      # browser drops the primary artifact for the active tab.
      heroBlock = l: ''
        <div class="lv pack-panel lv-${l.key}" draggable="true" ondragstart="dragPack(event)" data-url="${dlKey l.primary}" title="Drag this card onto your launcher">
          <span class="pack-icon">
            <img class="launcher-logo" src="/assets/${launcherLogos.${l.key}}" alt="${l.label} logo" />
          </span>
          <div class="hero-text">
            <div class="hero-title">${l.heroTitle}</div>
            <div class="hero-hint">${l.heroHint}</div>
          </div>
          <div class="hero-btns">
            <a class="btn primary" draggable="false" href="${dlKey l.primary}" title="${artifacts.${l.primary}.desc}">${l.heroBtn}</a>
            ${optionalString (l ? secondary)
              ''<a class="btn subtle" draggable="false" href="${dlKey l.secondary}" title="${artifacts.${l.secondary}.desc}">${l.secondaryLabel}</a>''}
          </div>
        </div>
      '';

      addressBit =
        if address != null then
          ''
            <span class="addr-row">
              <code class="copy addr" onclick="selectText(this)" title="click to select, then copy">${address}</code>
              <button class="copy-btn" onclick="copyAddr(this)" title="copy address" aria-label="copy address">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><rect x="9" y="9" width="11" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M5 15V5a2 2 0 0 1 2-2h8" fill="none" stroke="currentColor" stroke-width="2"/></svg>
              </button>
            </span>
          ''
        else
          ''<span class="addr muted">server address not configured</span>'';

      body =
        if !client then
          ''
            <p class="server-note">Server-side pack — no client modpack to install. Add the address above in your multiplayer list and join.</p>
          ''
        else if repo == null then
          ''
            <div class="muted">No release artifacts configured for this pack.</div>
          ''
        else
          ''
            <div class="pack-section">
              <h3 class="pack-section-title">Modpack</h3>
              <div class="pack-head">
                <span class="pack-avatar"><img class="pack-icon-img" alt="" />${loaderIcon s.loader}</span>
                <div class="pack-head-text">
                  <h3 class="pack-name" data-k="pack-name">${name}</h3>
                  <div class="pack-desc" data-k="pack-desc" hidden></div>
                  <div class="pack-meta">
                    <span class="chip" data-k="pack-version" hidden></span>
                    <span class="chip" data-k="mod-count" hidden></span>
                  </div>
                  <details class="mod-list" data-k="mod-list" hidden>
                    <summary>Mod list</summary>
                    <input class="mod-search" type="search" placeholder="filter mods…" oninput="filterMods(this)" />
                    <ul class="mods" data-k="mods"></ul>
                  </details>
                </div>
              </div>
              ${tabStrip}
              ${concatMapStringsSep "\n" heroBlock launchers}
            </div>
          '';
    in
    ''
      <section class="card${optionalString (!client) " server-only"}" data-name="${name}">
        <div class="card-head">
          ${optionalString (
            !client
          ) ''<span class="mini-icon"><img class="pack-icon-img" alt="" />${loaderIcon s.loader}</span>''}
          <div class="head-left">
            <h2>${name}</h2>
            <span class="stat motd" data-k="motd"></span>
          </div>
          <div class="head-right">
            <div class="chips">
              <span class="chip">${s.loader}</span>
              <span class="chip">${s.minecraftVersion}</span>
              ${optionalString (!client) ''<span class="chip chip-alt">server only</span>''}
              <span class="status-dot" title="server status"></span>
            </div>
            <div class="stats" data-status="${name}">
              <span class="stat players-stat"><b data-k="players">—</b> online</span>
              <span class="stat">TPS <b class="tps-val" data-k="tps">—</b>${
                optionalString (dashboardUrl != null) ''
                  <a class="dash-link" href="${dashboardUrl}/d/minecraft?var-server=${name}" target="_blank" rel="noopener" title="metrics dashboard (tailnet access only)"><svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><g fill="currentColor"><rect x="4" y="11" width="3.4" height="8"/><rect x="10.3" y="5" width="3.4" height="14"/><rect x="16.6" y="13" width="3.4" height="6"/></g></svg></a>
                ''
              }</span>
            </div>
          </div>
        </div>
        <div class="addr-line">${addressBit}</div>
        ${body}
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
        max-width: 1180px;
        margin: 0 auto;
        padding: 2rem 1rem 4rem;
        line-height: 1.5;
      }
      /* Wide screens: cards flow into two columns; cards in the same row
         stretch to equal height */
      .cards {
        display: grid; grid-template-columns: repeat(auto-fill, minmax(520px, 1fr));
        gap: 1rem; margin: 1rem 0;
      }
      @media (max-width: 560px) { .cards { grid-template-columns: 1fr; } }
      header h1 { font-weight: 700; margin: 0; font-size: 1.9rem; }
      header .sub { color: var(--dim); margin: .25rem 0 0; font-size: .9rem; }

      /* Tabs — full-width accent underline (house style), one strip per card */
      .tabs { display: flex; margin: 0 0 .8rem; border-bottom: 1px solid var(--border); }
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
        padding: 1rem 1.25rem 1.15rem;
      }
      .card.offline { opacity: .82; }
      .card-head { display: flex; align-items: flex-start; gap: .75rem; }
      .head-left { flex: 1 1 auto; min-width: 0; }
      .head-left h2 { margin: 0; font-size: 1.25rem; }
      .head-right {
        flex: 0 0 auto; display: flex; flex-direction: column;
        align-items: flex-end; gap: .3rem;
      }
      .chips { display: flex; align-items: center; gap: .4rem; flex-wrap: wrap; justify-content: flex-end; }
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

      /* Subtle join address on its own full-width row under the head */
      .addr-line { margin-top: .3rem; }
      .addr-row { display: flex; align-items: center; gap: .35rem; min-width: 0; }
      .addr {
        display: inline-block; font-size: .78rem; color: var(--dim);
        background: var(--inset); padding: .15rem .5rem; border-radius: 6px; cursor: pointer;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%;
      }
      code.addr:hover { background: #0d1418; color: #c8d0dc; }
      code.addr::selection { background: var(--accent); color: #12180b; }
      .addr.muted { cursor: default; background: none; padding-left: 0; }
      .copy-btn {
        flex: 0 0 auto; display: flex; align-items: center; justify-content: center;
        width: 22px; height: 22px; padding: 3px; background: none; border: 0;
        border-radius: 5px; color: var(--dim); cursor: pointer;
      }
      .copy-btn:hover { background: var(--hover); color: var(--text); }
      .copy-btn.copied { color: var(--accent); }
      .copy-btn svg { width: 100%; height: 100%; }

      /* Live stats — right column under the chips */
      .stats {
        display: flex; flex-direction: column; align-items: flex-end; gap: .1rem;
        font-size: .82rem; color: var(--dim);
      }
      .stats b { color: var(--text); font-weight: 700; }
      .motd { display: block; color: var(--dim); font-size: .82rem; margin-top: .15rem; }
      .tps-val.ok { color: var(--accent); }
      .tps-val.warn { color: var(--warning); }
      .tps-val.crit { color: var(--critical); }

      /* Launcher variants: only the selected one shows */
      .lv { display: none; }
      .lv::after { content: ""; display: block; clear: both; }
      body[data-launcher="prism"] .lv-prism,
      body[data-launcher="mrpack"] .lv-mrpack,
      body[data-launcher="curseforge"] .lv-curseforge { display: block; }

      /* Modpack section: pack identity + tab strip + one draggable panel per launcher */
      .pack-section { margin-top: .9rem; padding-top: .7rem; border-top: 1px solid var(--border); }
      .pack-section-title { margin: 0 0 .55rem; font-size: .95rem; font-weight: 700; }
      .pack-head { display: flex; align-items: flex-start; gap: .7rem; margin-bottom: .6rem; }
      .pack-avatar {
        flex: 0 0 auto; width: 44px; height: 44px; display: flex;
        align-items: center; justify-content: center; overflow: hidden;
        background: var(--inset); border: 1px solid var(--border); border-radius: 8px;
      }
      .pack-avatar .pack-icon-glyph { width: 28px; height: 28px; object-fit: contain; }
      .pack-head-text { min-width: 0; }
      .pack-name { margin: 0; font-size: 1.05rem; }
      .pack-desc { color: var(--dim); font-size: .82rem; margin-top: .1rem; }
      .pack-meta { display: flex; gap: .4rem; margin-top: .3rem; flex-wrap: wrap; }
      .pack-meta .chip:empty { display: none; }

      /* Searchable, collapsible mod list (lives in the pack description) */
      details.mod-list { margin-top: .35rem; color: var(--dim); font-size: .82rem; }
      details.mod-list summary {
        cursor: pointer; color: var(--dim); font-weight: 700; list-style: none; padding: .1rem 0;
      }
      details.mod-list summary:hover { color: var(--text); }
      details.mod-list summary::-webkit-details-marker { display: none; }
      details.mod-list summary::before { content: "▸ "; color: var(--accent); }
      details.mod-list[open] summary::before { content: "▾ "; }
      .mod-search {
        width: 100%; margin: .4rem 0; padding: .4rem .6rem; font: inherit; font-size: .85rem;
        background: var(--inset); color: var(--text);
        border: 1px solid var(--border); border-radius: 6px; outline: none;
      }
      .mod-search:focus { border-color: var(--accent-dark); }
      ul.mods {
        list-style: none; margin: 0; padding: 0; max-height: 240px; overflow-y: auto;
        columns: 2; column-gap: 1rem;
      }
      ul.mods li { padding: .1rem 0; break-inside: avoid; }
      ul.mods li[hidden] { display: none; }

      /* Player-list tooltip on the online count (native titles proved flaky) */
      .players-stat { position: relative; }
      .players-stat.has-players { cursor: help; text-decoration: underline dotted var(--dim); text-underline-offset: 3px; }
      .players-stat.has-players:hover::after {
        content: attr(data-players); position: absolute; right: 0; top: calc(100% + 4px);
        background: var(--inset); border: 1px solid var(--border); border-radius: 6px;
        padding: .4rem .6rem; color: var(--text); white-space: pre; text-align: left;
        font-size: .8rem; line-height: 1.4; z-index: 10; box-shadow: 0 4px 12px rgba(0,0,0,.4);
      }

      /* Metrics dashboard link next to TPS (revealed only if reachable) */
      .dash-link { color: var(--dim); margin-left: .35rem; vertical-align: middle; }
      .dash-link:hover { color: var(--accent); }
      .dash-link svg { width: 14px; height: 14px; }
      .pack-panel {
        background: var(--inset); border: 1px dashed var(--border); border-radius: 10px;
        padding: .9rem 1rem; cursor: grab;
        transition: border-color .08s, background .08s;
      }
      .pack-panel:hover { border-color: var(--accent-dark); }
      .pack-panel:active { cursor: grabbing; }
      .pack-icon {
        float: left; display: flex; align-items: center; justify-content: center;
        width: 104px; height: 104px; margin: 0 1.1rem .6rem 0;
        background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
        color: var(--accent); overflow: hidden; pointer-events: none;
      }
      .pack-icon .launcher-logo { width: 62px; height: 62px; object-fit: contain; }
      .pack-icon-img { display: none; width: 100%; height: 100%; object-fit: cover; }

      /* Small header avatar on server-only cards (server-icon / loader logo) */
      .mini-icon {
        flex: 0 0 auto; width: 40px; height: 40px; display: flex;
        align-items: center; justify-content: center; overflow: hidden;
        background: var(--inset); border: 1px solid var(--border); border-radius: 8px;
      }
      .mini-icon .pack-icon-glyph { width: 26px; height: 26px; object-fit: contain; }
      .hero-text { overflow: hidden; }
      .hero-title { font-size: 1.05rem; font-weight: 700; margin-bottom: .55rem; }
      /* Buttons clear the floated icon: full panel width, equal flex halves
         (a lone button stretches the whole way). Identical font/padding/height
         — the subtle variant differs only in colour. */
      .hero-btns { display: flex; align-items: stretch; flex-wrap: nowrap; gap: .5rem; min-width: 0; clear: both; padding-top: .65rem; }
      .hero-btns .btn {
        flex: 1 1 0; min-width: 0; text-align: center;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        display: flex; align-items: center; justify-content: center;
        font-size: .95rem; padding: .55rem 1.1rem;
      }
      .hero-hint { color: var(--dim); font-size: .78rem; margin-top: .5rem; }

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
      .btn.subtle { color: var(--dim); }
      .btn.subtle:hover { color: var(--text); }

      .muted { color: var(--dim); }
      .server-note { color: var(--dim); font-size: .9rem; margin: .9rem 0 0; }

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
      details.howto .lv { margin-top: 0; }
    </style>
    </head>
    <body data-launcher="prism">
    <header>
      <h1>Modpacks</h1>
      <p class="sub">Pick your launcher, grab a pack, and join the server.</p>
    </header>

    <div class="cards">
      ${concatStringsSep "\n" (mapAttrsToList serverCard servers)}
    </div>

    <details class="howto" open>
      <summary>How to install</summary>
      <div class="lv lv-prism">
        <ol>
          <li>Install <a href="https://prismlauncher.org/download/">PrismLauncher</a> (free, all platforms).</li>
          <li>Drag a pack card straight onto the Prism window — or click <b>Download for Prism</b> and drag the downloaded file onto Prism (<b>Add Instance → Import → Browse</b> also works).</li>
          <li>Launch. The pack fetches its mods on first start and keeps itself updated every launch.</li>
        </ol>
        <p>The <b>preloaded</b> variant bundles every mod up front — a much bigger download, but no wait on first launch.</p>
      </div>
      <div class="lv lv-mrpack">
        <ol>
          <li>Install the <a href="https://modrinth.com/app">Modrinth App</a>.</li>
          <li>Click <b>Download .mrpack</b> and open the downloaded file — the Modrinth App imports it.</li>
          <li>Launch from the app.</li>
        </ol>
        <p>The <code>.mrpack</code> doesn't self-update — check back here after pack updates.</p>
      </div>
      <div class="lv lv-curseforge">
        <ol>
          <li>Install the <a href="https://www.curseforge.com/download/app">CurseForge app</a>.</li>
          <li>Click <b>Download for CurseForge</b>, then in the app: <b>Create Custom Profile → Import</b> and pick the downloaded zip.</li>
          <li>Launch from the app.</li>
        </ol>
        <p>The CurseForge zip doesn't self-update — check back here after pack updates.</p>
      </div>
      <p>Copy the server address under a pack's title to join.</p>
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

      // Explicit copy button: a user-initiated clipboard write on a real
      // button is fine (the ad-blocker ClickFix heuristics target sneaky
      // copy-on-click of page text, which stays select-only above).
      function copyAddr(btn) {
        var code = btn.parentElement.querySelector("code.addr");
        var text = code.textContent;
        function flash() {
          btn.classList.add("copied");
          setTimeout(function () { btn.classList.remove("copied"); }, 1200);
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(flash, function () { selectText(code); });
        } else {
          selectText(code);
          try { document.execCommand("copy") && flash(); } catch (e) {}
        }
      }

      // Chromium: dragging the pack panel out of the window drops a real file
      // (e.g. straight onto the Prism window). Other browsers get the URL.
      function dragPack(e) {
        var url = e.currentTarget.dataset.url;
        var name = url.split("/").pop();
        e.dataTransfer.setData("DownloadURL", "application/octet-stream:" + name + ":" + url);
        e.dataTransfer.setData("text/uri-list", url);
      }

      function filterMods(input) {
        var q = input.value.toLowerCase();
        var items = input.parentElement.querySelectorAll(".mods li");
        for (var i = 0; i < items.length; i++) {
          items[i].hidden = items[i].textContent.toLowerCase().indexOf(q) < 0;
        }
      }

      // Note: the dashboard link shows for everyone. Reachability probing was
      // tried and abandoned — browsers' Local Network Access policy silently
      // blocks public sites from fetching tailnet (CGNAT) addresses, so a
      // probe can't distinguish "no access" from "browser refused to ask".
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
              var stat = pl.closest(".players-stat");
              if (stat) {
                var names = s.player_names || [];
                stat.classList.toggle("has-players", names.length > 0);
                var tip = names.join("\n");
                if (stat.dataset.players !== tip) stat.dataset.players = tip;
              }
            }
            // Packwiz metadata: pack name/description/version + mod list
            var pack = s.pack;
            if (pack) {
              var pn = box.querySelector("[data-k=pack-name]");
              if (pn && pack.name) pn.textContent = pack.name;
              var pd = box.querySelector("[data-k=pack-desc]");
              if (pd && pack.description) { pd.hidden = false; pd.textContent = pack.description; }
              var pv = box.querySelector("[data-k=pack-version]");
              if (pv && pack.version) { pv.hidden = false; pv.textContent = "v" + pack.version; }
              var mc = box.querySelector("[data-k=mod-count]");
              if (mc && pack.mod_count) { mc.hidden = false; mc.textContent = pack.mod_count + " mods"; }
              var ml = box.querySelector("[data-k=mod-list]");
              if (ml && pack.mods && pack.mods.length) {
                ml.hidden = false;
                var modsKey = pack.mods.join("|");
                if (ml.dataset.mods !== modsKey) {
                  ml.dataset.mods = modsKey;
                  ml.querySelector("summary").textContent = "Mod list (" + pack.mods.length + ")";
                  var ul = ml.querySelector(".mods");
                  ul.textContent = "";
                  for (var mi = 0; mi < pack.mods.length; mi++) {
                    var li = document.createElement("li");
                    li.textContent = pack.mods[mi];
                    ul.appendChild(li);
                  }
                }
              }
            }
            var tps = box.querySelector("[data-k=tps]");
            if (tps) {
              tps.textContent = (s.tps == null ? "—" : s.tps.toFixed(1));
              tps.className = "tps-val " + tpsClass(s.tps);
            }
            // Icon precedence: server-icon (favicon) -> pack icon -> loader logo.
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
pkgs.runCommand "minecraft-web-root" { } ''
  mkdir -p $out/assets
  cp ${./web-assets}/* $out/assets/
  cp ${pkgs.writeText "modpacks-index.html" html} $out/index.html
''
