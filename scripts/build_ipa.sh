#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project PTBrowser.xcodeproj -scheme PTBrowser \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceData -archivePath build/PTBrowser-Signed.xcarchive \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=96P5S5A5C3 \
  CODE_SIGN_IDENTITY='Apple Development' archive
xcodebuild -exportArchive -archivePath build/PTBrowser-Signed.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/Export
codesign --verify --deep --strict build/PTBrowser-Signed.xcarchive/Products/Applications/PTBrowser.app
