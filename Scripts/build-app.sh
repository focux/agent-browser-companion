#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/build/Agent Browser Companion.app"
CONTENTS_DIR="$APP_DIR/Contents"
APP_VERSION="${APP_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Resources/Info.plist")}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$PROJECT_DIR/Resources/Info.plist")}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-}"

cd "$PROJECT_DIR"
# The Xcode build-system backend in the current Xcode beta stamps SwiftPM
# executables with the deployment SDK instead of the SDK used to compile them.
# The native backend preserves the SDK stamp required for the current macOS UI.
swift build -c release --build-system native
BINARY_DIR="$(swift build -c release --build-system native --show-bin-path)"
BINARY_PATH="$BINARY_DIR/AgentBrowserCompanion"
EXPECTED_SDK="$(xcrun --sdk macosx --show-sdk-version)"
ACTUAL_SDK="$(xcrun vtool -show-build "$BINARY_PATH" | awk '/^[[:space:]]+sdk / { print $2; exit }')"

if [[ "$ACTUAL_SDK" != "$EXPECTED_SDK" ]]; then
    echo "error: executable is stamped with macOS SDK $ACTUAL_SDK; expected $EXPECTED_SDK" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BINARY_PATH" "$CONTENTS_DIR/MacOS/AgentBrowserCompanion"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

signing_arguments=(--force --sign "$CODE_SIGN_IDENTITY")
if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
    signing_arguments+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    signing_arguments+=(--options runtime --timestamp)
fi

codesign "${signing_arguments[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
