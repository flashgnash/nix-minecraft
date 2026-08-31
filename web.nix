# Generates the static modpack listing site served by services.minecraft-web.
# One card per enabled server, derived entirely from the module config:
# join address, packwiz URL, and one-click artifact downloads for packs whose
# packwizUrl points at a GitHub repo with rolling releases (the packwiz-tui
# CI layout: <repo>-prism.zip, <repo>-prism-preinstalled.zip, <repo>.mrpack,
# <repo>-curseforge.zip published under releases/latest).
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

  serverCard =
    name: s:
    let
      repo = githubRepo s.packwizUrl;
      dl =
        artifact:
        "https://github.com/${elemAt repo 0}/${elemAt repo 1}/releases/latest/download/${elemAt repo 1}${artifact}";
      address = if domainSuffix != null then "${name}.${domainSuffix}" else null;
      buttons =
        if repo != null then ''
          <div class="buttons">
            <a class="btn primary" href="${dl "-prism.zip"}" title="Self-updating PrismLauncher instance (small download, fetches mods on first launch)">Install — Prism</a>
            <a class="btn" href="${dl "-prism-preinstalled.zip"}" title="PrismLauncher instance with all mods bundled (large download, instant first launch)">Prism (preinstalled)</a>
            <a class="btn" href="${dl ".mrpack"}" title="Modrinth format — double-click imports into Prism or the Modrinth App">.mrpack</a>
            <a class="btn" href="${dl "-curseforge.zip"}" title="CurseForge launcher import">CurseForge</a>
          </div>
        '' else ''
          <div class="buttons"><span class="muted">no release artifacts configured</span></div>
        '';
    in ''
      <section class="card">
        <h2>${name}</h2>
        <div class="meta">
          <span class="chip">${s.loader}</span>
          <span class="chip">${s.minecraftVersion}</span>
        </div>
        ${optionalString (address != null) ''
          <p class="row">server address
            <code class="copy" onclick="copyText(this)" title="click to copy">${address}</code>
          </p>
        ''}
        <p class="row">packwiz url
          <code class="copy" onclick="copyText(this)" title="click to copy">${s.packwizUrl}</code>
        </p>
        ${buttons}
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
      :root { color-scheme: dark; }
      body { font-family: system-ui, sans-serif; background: #16181d; color: #e6e6e6;
             max-width: 720px; margin: 0 auto; padding: 2rem 1rem; }
      h1 { font-weight: 600; }
      .card { background: #1f232b; border: 1px solid #2e3440; border-radius: 12px;
              padding: 1rem 1.25rem; margin: 1rem 0; }
      .card h2 { margin: 0 0 .5rem; font-size: 1.2rem; }
      .chip { background: #2e3440; border-radius: 999px; padding: .15rem .6rem;
              font-size: .8rem; margin-right: .4rem; }
      .row { font-size: .85rem; color: #9aa0ac; margin: .5rem 0; }
      code.copy { background: #14161b; padding: .2rem .5rem; border-radius: 6px;
                  cursor: pointer; color: #c8d0dc; margin-left: .4rem; }
      code.copy:hover { background: #0f1115; }
      .buttons { margin-top: .75rem; display: flex; flex-wrap: wrap; gap: .5rem; }
      .btn { background: #2e3440; color: #e6e6e6; text-decoration: none;
             padding: .45rem .9rem; border-radius: 8px; font-size: .9rem; }
      .btn.primary { background: #3b6ea5; }
      .btn:hover { filter: brightness(1.15); }
      .muted { color: #6b7280; font-size: .85rem; }
      details { margin-top: 2rem; color: #9aa0ac; font-size: .9rem; }
      details code { background: #14161b; padding: .1rem .4rem; border-radius: 4px; }
      #copied { position: fixed; bottom: 1rem; right: 1rem; background: #3b6ea5;
                padding: .5rem 1rem; border-radius: 8px; opacity: 0; transition: opacity .3s; }
    </style>
    </head>
    <body>
    <h1>Modpacks</h1>
    ${concatStringsSep "\n" (mapAttrsToList serverCard servers)}
    <details>
      <summary>How to install (Windows / Mac / Linux)</summary>
      <ol>
        <li>Install <a href="https://prismlauncher.org/download/">PrismLauncher</a> (free, all platforms).</li>
        <li>Click <b>Install — Prism</b> above to download the pack.</li>
        <li>In Prism: <b>Add Instance → Import → Browse</b> and pick the downloaded zip — or just drag the zip onto the Prism window.</li>
        <li>Launch. The pack downloads its mods on first start and keeps itself updated on every launch.</li>
      </ol>
      <p>Using the Modrinth App or another launcher? Grab the <code>.mrpack</code> or CurseForge zip instead (these don't self-update). The server address is prefilled in your multiplayer list where supported — otherwise click it above to copy.</p>
    </details>
    <div id="copied">copied!</div>
    <script>
      function copyText(el) {
        navigator.clipboard.writeText(el.textContent).then(() => {
          const t = document.getElementById('copied');
          t.style.opacity = 1;
          setTimeout(() => t.style.opacity = 0, 1200);
        });
      }
    </script>
    </body>
    </html>
  '';
in
pkgs.writeTextDir "index.html" html
