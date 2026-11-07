#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project WoXing.xcodeproj -target WoXing -configuration Release -sdk iphoneos SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO build
mkdir -p build/ipa/Payload
rm -rf build/ipa/Payload/WoXing.app
cp -R build/Release-iphoneos/WoXing.app build/ipa/Payload/
cd build/ipa
zip -qry ../WoXing-unsigned.ipa Payload
printf '\n未签名 IPA: %s\n' "$(cd .. && pwd)/WoXing-unsigned.ipa"
