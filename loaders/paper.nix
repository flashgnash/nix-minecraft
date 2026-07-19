{ pkgs }:
import ./papermc.nix {
  inherit pkgs;
  project = "paper";
}
