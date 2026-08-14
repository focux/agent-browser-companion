#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <ws-or-wss-endpoint> [session-name]" >&2
    exit 64
fi

ENDPOINT="$1"
SESSION_NAME="${2:-}"
APP_PATH="${0:A:h:h}/build/Agent Browser Companion.app"
SESSION_URL="$(swift -e '
import Foundation
var components = URLComponents()
components.scheme = "agentbrowser-companion"
components.host = "add"
components.queryItems = [
    URLQueryItem(name: "endpoint", value: CommandLine.arguments[1]),
    URLQueryItem(name: "name", value: CommandLine.arguments[2])
]
print(components.url!.absoluteString)
' "$ENDPOINT" "$SESSION_NAME")"

open -a "$APP_PATH" "$SESSION_URL"
