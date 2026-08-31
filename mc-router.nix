# mc-router: hostname-based Minecraft reverse proxy (github.com/itzg/mc-router).
# Not in nixpkgs, so built here. Takes the host's pkgs (needs a recent Go).
{ pkgs }:
pkgs.buildGoModule rec {
  pname = "mc-router";
  version = "1.46.4";

  src = pkgs.fetchFromGitHub {
    owner = "itzg";
    repo = "mc-router";
    rev = "v${version}";
    hash = "sha256-ryQONytzB8ftZHPlbDHg8L8/btJBdt6A9I151aoUSf4=";
  };

  vendorHash = "sha256-xB2TDI4Nb+MaK4YkNmbnmpZxxD8PMzxWmzK6HWqY3R8=";

  subPackages = [ "cmd/mc-router" ];

  meta.description = "Routes Minecraft client connections to backend servers based on the requested hostname";
}
