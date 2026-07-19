{ pkgs }:
let
  # Fabric's command-line installer is versioned independently of the
  # loader/Minecraft versions; it rarely changes and is broadly compatible.
  installerVersion = "1.1.1";
in
{
  # The Fabric installer in "server" mode writes a runnable
  # fabric-server-launch.jar and (-downloadMinecraft) fetches the
  # matching vanilla server jar, so the server is ready offline after.
  installCmd =
    {
      javaPackage,
      minecraftVersion,
      loaderVersion,
      ...
    }:
    ''
      ${pkgs.wget}/bin/wget https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVersion}/fabric-installer-${installerVersion}.jar
      ${javaPackage}/bin/java -jar fabric-installer-${installerVersion}.jar server \
        -mcversion ${minecraftVersion} \
        -loader ${loaderVersion} \
        -downloadMinecraft
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
        -jar fabric-server-launch.jar \
        nogui
    '';
}
