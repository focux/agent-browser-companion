#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version-or-tag>" >&2
    exit 64
fi

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TAG="$1"
VERSION="${TAG#v}"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    echo "error: expected a semantic version such as v1.2.3" >&2
    exit 64
fi

export APP_VERSION="$VERSION"
export APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
NOTARIZE="${NOTARIZE:-false}"

if [[ "$NOTARIZE" != "true" && "$NOTARIZE" != "false" ]]; then
    echo "error: NOTARIZE must be true or false" >&2
    exit 64
fi

if [[ "$NOTARIZE" == "true" && "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
    echo "error: notarized releases require a Developer ID signing identity" >&2
    exit 64
fi

"$SCRIPT_DIR/build-app.sh"

DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$PROJECT_DIR/build/Agent Browser Companion.app"
ARCHIVE_NAME="Agent-Browser-Companion-${VERSION}.zip"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"

if [[ "$NOTARIZE" == "true" ]]; then
    signature_details="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
    if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
        echo "error: notarized releases must be signed with a Developer ID Application certificate" >&2
        exit 65
    fi
    if [[ "$signature_details" != *"(runtime)"* || "$signature_details" != *"Timestamp="* ]]; then
        echo "error: Developer ID signature is missing Hardened Runtime or a secure timestamp" >&2
        exit 65
    fi

    NOTARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/agent-browser-companion-notary.XXXXXX")"
    trap 'rm -rf "$NOTARY_DIRECTORY"' EXIT
    NOTARY_ARCHIVE="$NOTARY_DIRECTORY/Agent-Browser-Companion-${VERSION}-notarization.zip"
    NOTARY_TIMEOUT="${NOTARYTOOL_TIMEOUT:-30m}"
    notary_arguments=()

    if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
        notary_arguments+=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
        if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
            notary_arguments+=(--keychain "$NOTARYTOOL_KEYCHAIN")
        fi
    elif [[ -n "${NOTARYTOOL_API_KEY_PATH:-}" && -n "${NOTARYTOOL_API_KEY_ID:-}" ]]; then
        if [[ ! -f "$NOTARYTOOL_API_KEY_PATH" ]]; then
            echo "error: notarization API key does not exist: $NOTARYTOOL_API_KEY_PATH" >&2
            exit 66
        fi
        notary_arguments+=(--key "$NOTARYTOOL_API_KEY_PATH" --key-id "$NOTARYTOOL_API_KEY_ID")
        if [[ -n "${NOTARYTOOL_API_ISSUER_ID:-}" ]]; then
            notary_arguments+=(--issuer "$NOTARYTOOL_API_ISSUER_ID")
        fi
    else
        echo "error: set NOTARYTOOL_KEYCHAIN_PROFILE or the NOTARYTOOL_API_KEY_PATH and NOTARYTOOL_API_KEY_ID pair" >&2
        exit 64
    fi

    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" "${notary_arguments[@]}" --wait --timeout "$NOTARY_TIMEOUT"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$CHECKSUM_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/$ARCHIVE_NAME"

(
    cd "$DIST_DIR"
    shasum -a 256 "$ARCHIVE_NAME" > "$CHECKSUM_NAME"
)

echo "$DIST_DIR/$ARCHIVE_NAME"
echo "$DIST_DIR/$CHECKSUM_NAME"
