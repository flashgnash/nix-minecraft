{ pkgs }:
{
  forge = import ./forge.nix { inherit pkgs; };
  neoforge = import ./neoforge.nix { inherit pkgs; };
  fabric = import ./fabric.nix { inherit pkgs; };
  paper = import ./paper.nix { inherit pkgs; };
  folia = import ./folia.nix { inherit pkgs; };
}
