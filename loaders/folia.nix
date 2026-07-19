{ pkgs }:
import ./papermc.nix {
  inherit pkgs;
  project = "folia";
}
