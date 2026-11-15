#!/bin/bash
# Builds Unreeled for TestFlight's internal testing (docs/RELEASING.md, "TestFlight, for the team").
#
#   tools/testflight.sh check  <bundle ID>   archives, signs, and has App Store Connect validate
#                                            the package: nothing is uploaded
#   tools/testflight.sh upload <bundle ID>   the same, then uploads that package
#
# It signs with an App Store Connect API key, not with an account saved in Xcode. The key's folder
# is ~/.config/unreeled/appstoreconnect, or the one named by UNREELED_ASC_KEYS: it holds the key
# as downloaded, AuthKey_<key ID>.p8, and issuer-id.txt with the Issuer ID. Neither ever goes in
# the repository. The team comes from Config/Local.xcconfig; the bundle ID in that file stays as
# it is, and the one given here is used for this build only.
#
# Everything is written to build/testflight, which git ignores.
set -euo pipefail

mode="${1:-}"
bundle_id="${2:-}"
if [[ "$mode" != "check" && "$mode" != "upload" ]] || [[ -z "$bundle_id" ]]; then
  echo "usage: tools/testflight.sh check|upload <bundle ID>" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
keys="${UNREELED_ASC_KEYS:-$HOME/.config/unreeled/appstoreconnect}"
key="$(find "$keys" -maxdepth 1 -name 'AuthKey_*.p8' 2>/dev/null | head -1 || true)"
if [[ -z "$key" || ! -f "$keys/issuer-id.txt" ]]; then
  echo "No AuthKey_<key ID>.p8 with issuer-id.txt in $keys" >&2
  exit 2
fi
key_id="$(basename "$key" .p8)"
key_id="${key_id#AuthKey_}"
issuer="$(tr -d '[:space:]' < "$keys/issuer-id.txt")"
team="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$root/Config/Local.xcconfig" 2>/dev/null | head -1 || true)"
if [[ -z "$team" ]]; then
  echo "No DEVELOPMENT_TEAM in Config/Local.xcconfig" >&2
  exit 2
fi
signing=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
apple=(--api-key "$key_id" --api-issuer "$issuer" --p8-file-path "$key")

out="$root/build/testflight"
mkdir -p "$out"
rm -rf "$out/Unreeled.xcarchive" "$out/export"

# The tools' output names the key and the team, so it goes to a file; only a failure's end is shown.
run() {
  local log="$out/$1.log"
  shift
  if ! "$@" > "$log" 2>&1; then
    tail -n 25 "$log" >&2
    echo "Failed. The whole output is in $log" >&2
    exit 1
  fi
}

echo "Archiving as $bundle_id"
run archive xcodebuild -project "$root/Unreeled.xcodeproj" -scheme "Unreeled for iPhone" -configuration Release \
  -destination generic/platform=iOS -derivedDataPath "$out/derived" -archivePath "$out/Unreeled.xcarchive" \
  "${signing[@]}" UNREELED_BUNDLE_ID="$bundle_id" archive

# Signed for App Store Connect, and marked so that the build can only ever reach internal testers.
options="$out/ExportOptions.plist"
rm -f "$options"
/usr/libexec/PlistBuddy \
  -c "Add :method string app-store-connect" \
  -c "Add :destination string export" \
  -c "Add :signingStyle string automatic" \
  -c "Add :teamID string $team" \
  -c "Add :testFlightInternalTestingOnly bool true" \
  -c "Add :manageAppVersionAndBuildNumber bool false" \
  "$options" > /dev/null
echo "Signing for App Store Connect"
run export xcodebuild -exportArchive -archivePath "$out/Unreeled.xcarchive" \
  -exportOptionsPlist "$options" -exportPath "$out/export" "${signing[@]}"

ipa="$out/export/Unreeled.ipa"
info="$out/Unreeled.xcarchive/Products/Applications/Unreeled.app/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info"))"

echo "Asking App Store Connect to check version $version"
run validate xcrun altool --validate-app "$ipa" "${apple[@]}"
if [[ "$mode" == "upload" ]]; then
  echo "Uploading"
  run upload xcrun altool --upload-package "$ipa" "${apple[@]}"
  echo "Uploaded $bundle_id $version. It shows in TestFlight once Apple has processed it."
else
  echo "App Store Connect found no errors in $bundle_id $version. Nothing was uploaded: $ipa"
fi
