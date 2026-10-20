# tv-gateway-updates

Signed script updates for a router that keeps a TV online. The router pulls `manifest`,
`manifest.sig` and the listed files from here; it installs nothing without a valid usign signature
from the owner's key and matching SHA-256 checksums. No secrets are stored here.

Published with `tools/make_update.py publish` from the (private) main repo. Do not edit by hand.
