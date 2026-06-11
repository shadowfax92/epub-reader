#!/bin/bash
# Installs the built iphoneos .app as a launchable Mac app ("Designed for iPad").
# macOS only launches iOS bundles that are (a) development-signed with a
# provisioning profile listing this Mac's provisioning UDID and (b) installed in
# the App Store wrapper layout (Foo.app/Wrapper/Foo.app + WrappedBundle symlink).
# Ad-hoc signatures and raw iOS bundles are refused by LaunchServices, so this
# reuses the Xcode-managed dev identity + team profile already on the machine.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

APP_BUNDLE="${1:?usage: install-mac.sh <built .app> [install dir]}"
INSTALL_DIR="${2:-/Applications}"
[ -d "$APP_BUNDLE" ] || die "app bundle not found: $APP_BUNDLE (run 'make build-mac' first)"
if [ ! -w "$INSTALL_DIR" ]; then
  echo "warning: $INSTALL_DIR is not writable — installing to $HOME/Applications instead" >&2
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi

APP_NAME="$(basename "$APP_BUNDLE" .app)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Info.plist")"

IDENTITIES=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2}')
[ -n "$IDENTITIES" ] || die "no 'Apple Development' signing identity in the keychain.
Open Xcode → Settings → Accounts and sign in with your Apple ID once (same setup the iPhone flow needs)."

UDID=$(system_profiler SPHardwareDataType | awk '/Provisioning UDID/{print $NF}')
[ -n "$UDID" ] || die "could not read this Mac's provisioning UDID"

# Find an (identity, profile) pair: profile must provision this Mac, embed the
# identity's certificate, match the bundle id, and not be expired.
PROFILE="" IDENTITY="" TEAM=""
DECODED=$(mktemp)
trap 'rm -rf "$DECODED" ${STAGE:+"$STAGE"}' EXIT
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for p in ~/Library/Developer/Xcode/UserData/"Provisioning Profiles"/*.mobileprovision \
         ~/Library/MobileDevice/"Provisioning Profiles"/*.mobileprovision; do
  [ -f "$p" ] || continue
  security cms -D -i "$p" > "$DECODED" 2>/dev/null || continue
  plutil -convert xml1 "$DECODED" 2>/dev/null || continue
  grep -q "$UDID" "$DECODED" || continue
  expiry=$(plutil -extract ExpirationDate raw -o - "$DECODED" 2>/dev/null) || continue
  [ "$expiry" \> "$NOW" ] || continue
  team=$(plutil -extract TeamIdentifier.0 raw -o - "$DECODED" 2>/dev/null) || continue
  app_id=$(plutil -extract Entitlements.application-identifier raw -o - "$DECODED" 2>/dev/null) || continue
  case "$app_id" in
    "$team.$BUNDLE_ID"|"$team.*") ;;
    *) continue ;;
  esac
  i=0
  while cert_sha=$(plutil -extract DeveloperCertificates.$i raw -o - "$DECODED" 2>/dev/null \
      | base64 -d 2>/dev/null | shasum -a 1 | awk '{print toupper($1)}'); do
    for id in $IDENTITIES; do
      if [ "$cert_sha" = "$id" ]; then
        PROFILE="$p" IDENTITY="$id" TEAM="$team"
        break 3
      fi
    done
    i=$((i+1))
  done
done
[ -n "$PROFILE" ] || die "no provisioning profile covers this Mac (UDID $UDID) for $BUNDLE_ID.
Run any project once from Xcode with destination 'My Mac (Designed for iPad)' to let Xcode create one, then retry."

echo "Signing with team $TEAM, profile: $(basename "$PROFILE")"

STAGE=$(mktemp -d)
ditto "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
cp "$PROFILE" "$STAGE/$APP_NAME.app/embedded.mobileprovision"
cat > "$STAGE/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM</string>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
codesign --force --entitlements "$STAGE/entitlements.plist" -s "$IDENTITY" "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"

TARGET="$INSTALL_DIR/$APP_NAME.app"
rm -rf "$TARGET"
mkdir -p "$TARGET/Wrapper"
ditto "$STAGE/$APP_NAME.app" "$TARGET/Wrapper/$APP_NAME.app"
ln -s "Wrapper/$APP_NAME.app" "$TARGET/WrappedBundle"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"

echo "Installed: $TARGET"
echo "Run with:  open '$TARGET'"
