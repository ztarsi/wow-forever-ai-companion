#!/bin/bash
# Select Codex explicitly, then use the same setup and scheduler as every provider.
HERE="$(cd "$(dirname "$0")" && pwd)"
export AIC_AUTO_PROVIDER=codex
exec /bin/bash "$HERE/Install-Mac.command"
