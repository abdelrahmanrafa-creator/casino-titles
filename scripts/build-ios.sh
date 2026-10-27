#!/bin/bash
set -euo pipefail
[ "$(uname)" = Darwin ] || { echo "iOS requires macOS and Xcode."; exit 1; }
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to your Apple developer team ID}"
npm run build:native
npx cap sync ios
mkdir -p release/ios
cat > release/ios/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>method</key><string>${IOS_EXPORT_METHOD:-debugging}</string><key>teamID</key><string>$APPLE_TEAM_ID</string><key>signingStyle</key><string>automatic</string></dict></plist>
EOF
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Release -destination 'generic/platform=iOS' -archivePath release/ios/CasinoTitles.xcarchive DEVELOPMENT_TEAM="$APPLE_TEAM_ID" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath release/ios/CasinoTitles.xcarchive -exportOptionsPlist release/ios/ExportOptions.plist -exportPath release/ios -allowProvisioningUpdates
