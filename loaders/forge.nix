{ pkgs }:
{
  installCmd =
    {
      javaPackage,
      minecraftVersion,
      loaderVersion,
      ...
    }:
    let
      installerUrl =
        "https://maven.minecraftforge.net/net/minecraftforge/forge/${minecraftVersion}-${loaderVersion}/forge-${minecraftVersion}-${loaderVersion}-installer.jar";
      installerJar = "forge-${minecraftVersion}-${loaderVersion}-installer.jar";
    in
    ''
      ${pkgs.wget}/bin/wget "${installerUrl}"
      ${javaPackage}/bin/java -jar "${installerJar}" --installServer
    '';

  launchCmd =
    {
      javaPackage,
      ramGb,
      serverDir,
      minecraftVersion,
      loaderVersion,
    }:
    # Modern Forge (1.17+) ships an @-args file from the installer;
    # legacy Forge (pre-1.17, e.g. 1.8.9) ships a runnable universal
    # jar instead. Detect at runtime so both work.
    pkgs.writeShellScript "forge-launch-${minecraftVersion}-${loaderVersion}" ''
      argsFile="${serverDir}/libraries/net/minecraftforge/forge/${minecraftVersion}-${loaderVersion}/unix_args.txt"
      if [ -f "$argsFile" ]; then
        exec ${javaPackage}/bin/java -Xmx${toString ramGb}G -Xms${toString ramGb}G @"$argsFile" nogui
      else
        exec ${javaPackage}/bin/java -Xmx${toString ramGb}G -Xms${toString ramGb}G \
          -jar "${serverDir}/forge-${minecraftVersion}-${loaderVersion}-universal.jar" nogui
      fi
    '';
}
