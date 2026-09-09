# JVM memory + GC flags for the server launch commands.
#
# With aikar = true (the default) this is Aikar's flag set — the
# community-standard G1 tuning for Minecraft servers (https://mcflags.emc.gs):
# a much larger young generation and an early-starting concurrent cycle so G1
# collects gradually instead of stalling the tick thread with panic mixed
# collections. Two values scale at the >= 12 GB heap boundary per the
# published recommendations. It tunes within the configured heap — no extra
# memory headroom needed (unlike ZGC).
#
# minRamGb switches from a pinned heap (Xms=Xmx + AlwaysPreTouch, Aikar's
# recommendation for a dedicated box) to a dynamic one: the heap starts at
# minRamGb and unused pages are returned to the OS when idle, so co-hosted
# servers share RAM instead of each locking their full allocation. With G1
# that adds a periodic concurrent cycle (JEP 346) to drive the uncommit;
# with zgc = true uncommit is native and softMaxRamGb sets the size ZGC
# tries to stay under, bursting to ramGb only when needed.
{
  lib,
  ramGb,
  minRamGb ? null,
  aikar ? true,
  zgc ? false,
  softMaxRamGb ? null,
}:
let
  big = ramGb >= 12;
  dynamic = minRamGb != null;
  heap = [
    "-Xmx${toString ramGb}G"
    "-Xms${toString (if dynamic then minRamGb else ramGb)}G"
  ];
  zgcFlags = [
    # Generational ZGC is the default on JDK 23+; the ZGenerational flag is
    # deliberately not passed since JDK 24+ rejects it.
    "-XX:+UseZGC"
    "-XX:ZUncommitDelay=60"
  ]
  ++ lib.optional (softMaxRamGb != null) "-XX:SoftMaxHeapSize=${toString softMaxRamGb}G";
  aikarFlags = [
    "-XX:+UseG1GC"
    "-XX:+ParallelRefProcEnabled"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+DisableExplicitGC"
  ]
  ++ lib.optional (!dynamic) "-XX:+AlwaysPreTouch"
  ++ lib.optional dynamic "-XX:G1PeriodicGCInterval=300000"
  ++ [
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
lib.concatStringsSep " " (heap ++ (if zgc then zgcFlags else lib.optionals aikar aikarFlags))
