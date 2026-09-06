# JVM memory + GC flags for the server launch commands.
#
# With aikar = true (the default) this is Aikar's flag set — the
# community-standard G1 tuning for Minecraft servers (https://mcflags.emc.gs):
# a much larger young generation and an early-starting concurrent cycle so G1
# collects gradually instead of stalling the tick thread with panic mixed
# collections. Two values scale at the >= 12 GB heap boundary per the
# published recommendations. It tunes within the configured heap — no extra
# memory headroom needed (unlike ZGC).
{
  lib,
  ramGb,
  aikar ? true,
}:
let
  big = ramGb >= 12;
  heap = [
    "-Xmx${toString ramGb}G"
    "-Xms${toString ramGb}G"
  ];
  aikarFlags = [
    "-XX:+UseG1GC"
    "-XX:+ParallelRefProcEnabled"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+DisableExplicitGC"
    "-XX:+AlwaysPreTouch"
    "-XX:G1NewSizePercent=${if big then "40" else "30"}"
    "-XX:G1MaxNewSizePercent=${if big then "50" else "40"}"
    "-XX:G1HeapRegionSize=${if big then "16M" else "8M"}"
    "-XX:G1ReservePercent=${if big then "15" else "20"}"
    "-XX:G1HeapWastePercent=5"
    "-XX:G1MixedGCCountTarget=4"
    "-XX:InitiatingHeapOccupancyPercent=${if big then "20" else "15"}"
    "-XX:G1MixedGCLiveThresholdPercent=90"
    "-XX:G1RSetUpdatingPauseTimePercent=5"
    "-XX:SurvivorRatio=32"
    "-XX:+PerfDisableSharedMem"
    "-XX:MaxTenuringThreshold=1"
    "-Dusing.aikars.flags=https://mcflags.emc.gs"
    "-Daikars.new.flags=true"
  ];
in
lib.concatStringsSep " " (heap ++ lib.optionals aikar aikarFlags)
