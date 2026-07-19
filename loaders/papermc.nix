{ pkgs, project }:
{
  installCmd =
    {
      minecraftVersion,
      paperBuild,
      ...
    }:
    ''
      buildsUrl="https://fill.papermc.io/v3/projects/${project}/versions/${minecraftVersion}/builds"
      userAgent="nix-minecraft/1.0 (https://github.com/flashgnash/nix-minecraft)"
      builds="$(${pkgs.curl}/bin/curl -fsSL -H "User-Agent: $userAgent" "$buildsUrl")"

      if [ "${paperBuild}" = latest ]; then
        downloadUrl="$(printf '%s' "$builds" | ${pkgs.jq}/bin/jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // empty')"
      else
        downloadUrl="$(printf '%s' "$builds" | ${pkgs.jq}/bin/jq -r --arg build "${paperBuild}" 'first(.[] | select((.id | tostring) == $build) | .downloads."server:default".url) // empty')"
      fi

      if [ -z "$downloadUrl" ]; then
        echo "No ${project} build '${paperBuild}' found for Minecraft ${minecraftVersion}" >&2
        exit 1
      fi

      ${pkgs.curl}/bin/curl -fL -H "User-Agent: $userAgent" -o server.jar.tmp "$downloadUrl"
      mv server.jar.tmp server.jar
    '';

  launchCmd =
    {
      javaPackage,
      ramGb,
      ...
    }:
    ''
      ${javaPackage}/bin/java \
        -Xmx${toString ramGb}G \
        -Xms${toString ramGb}G \
        -jar server.jar \
        nogui
    '';
}
