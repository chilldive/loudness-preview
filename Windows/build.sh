#!/bin/zsh
# Builds the Windows (x64) version: WebAssembly core → Electron app → zip.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.local/opt/node/bin:$HOME/.local/opt/zig:$PATH"
./wasm/build.sh
cp wasm/lpcore.wasm wasm/lpcore.js app/ui/
mkdir -p app/assets
for s in 16 24 32 48 64 128 256; do sips -s format png -Z $s ../AppIcon.icns --out app/assets/icon$s.png >/dev/null; done
node make-ico.mjs
cd app
[ -d node_modules ] || npm install
rm -rf ../dist
npx @electron/packager . "Loudness Preview" --platform=win32 --arch=x64 --out=../dist --overwrite \
  --icon=assets/icon.ico --app-version=1.1.0 --asar \
  --ignore='^/assets/icon[0-9]+\.png$' \
  --win32metadata.ProductName="Loudness Preview" --win32metadata.FileDescription="Loudness Preview" \
  --win32metadata.CompanyName="chilldive"
cd ../dist
rm -f "Loudness Preview-win32-x64.zip"
ditto -c -k --keepParent "Loudness Preview-win32-x64" "Loudness Preview-win32-x64.zip"
ls -lh "Loudness Preview-win32-x64.zip"
