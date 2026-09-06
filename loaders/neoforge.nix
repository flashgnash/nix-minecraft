{ pkgs }:
{
  installCmd =
    {
      javaPackage,
      loaderVersion,
      ...
    }:
    let
      installerUrl =
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/${loaderVersion}/neoforge-${loaderVersion}-installer.jar";
      installerJar = "neoforge-${loaderVersion}-installer.jar";
    in
    ''
      ${pkgs.wget}/bin/wget "${installerUrl}"
      ${javaPackage}/bin/java -jar "${installerJar}" --installServer
    '';

  launchCmd =
    {
      javaPackage,
      jvmFlags,
      loaderVersion,
      ...
    }:
    ''
      ${javaPackage}/bin/java \
        ${jvmFlags} \
        @libraries/net/neoforged/neoforge/${loaderVersion}/unix_args.txt \
        nogui
    '';
}
