# Ideas

## Protocol-version default routing for mc-router

Raw-IP / root-domain connections currently go to a single static
`defaultServer`. The Minecraft handshake includes the client's protocol
version (1.21.1 = 767, …), so the router could pick the backend whose
`minecraftVersion` matches the connecting client — making the raw IP "just
work" whenever servers run distinct MC versions.

- mc-router doesn't support this; needs a small Go patch (we already build it
  from source in `mc-router.nix`, so carrying a patch — or PRing upstream —
  is easy): e.g. `-default-by-protocol "767=host:port,…"`, consulted when no
  hostname mapping matches.
- The nix module can derive the protocol table automatically from each
  server's `minecraftVersion` (needs a static MC-version → protocol-number
  lookup table, extended occasionally for new releases).
- Modloader (vanilla vs forge-family) is also detectable from FML markers in
  the handshake hostname field; mod count/list is NOT available at routing
  time (negotiated after login).
