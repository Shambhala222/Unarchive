#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Unarchive"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
RESOURCES_DIR="$CONTENTS/Resources"
ICONSET="$DIST/AppIcon.iconset"
DOWNLOADS="${HOME}/Downloads"
DMG="$DOWNLOADS/${APP_NAME}.dmg"
STAGE="$DIST/dmg"

export MACOSX_DEPLOYMENT_TARGET=14.0

echo "→ Swift-Release bauen"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/Unarchive"
if [[ ! -x "$BIN" ]]; then
  echo "Binary nicht gefunden: $BIN" >&2
  exit 1
fi

echo "→ App-Bundle anlegen"
rm -rf "$DIST"
mkdir -p "$MACOS" "$HELPERS" "$RESOURCES_DIR" "$ICONSET" "$STAGE"

cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

echo "→ Engines einbetten"
cp /opt/homebrew/bin/unar /opt/homebrew/bin/lsar /opt/homebrew/bin/7zz "$HELPERS/"
UNRAR_BIN=""
if [[ -x /opt/homebrew/bin/unrar ]]; then
  UNRAR_BIN=/opt/homebrew/bin/unrar
elif [[ -x /usr/local/bin/unrar ]]; then
  UNRAR_BIN=/usr/local/bin/unrar
fi
if [[ -z "$UNRAR_BIN" ]]; then
  echo "unrar fehlt. Bitte installieren: brew install --cask rar" >&2
  exit 1
fi
cp -L "$UNRAR_BIN" "$HELPERS/unrar"
chmod +x "$HELPERS/unar" "$HELPERS/lsar" "$HELPERS/7zz" "$HELPERS/unrar"
xattr -cr "$HELPERS/unrar" 2>/dev/null || true
if [[ -f /opt/homebrew/Cellar/unar/1.10.8_7/LICENSE ]]; then
  cp /opt/homebrew/Cellar/unar/1.10.8_7/LICENSE "$RESOURCES_DIR/UNAR-LICENSE"
fi
if [[ -f /opt/homebrew/Cellar/sevenzip/26.02/LICENSE ]]; then
  cp /opt/homebrew/Cellar/sevenzip/26.02/LICENSE "$RESOURCES_DIR/SEVENZIP-LICENSE" 2>/dev/null || true
fi
UNRAR_LICENSE=(/opt/homebrew/Caskroom/rar/*/rar/license.txt(N))
if (( ${#UNRAR_LICENSE} )); then
  cp "${UNRAR_LICENSE[1]}" "$RESOURCES_DIR/UNRAR-LICENSE"
fi

echo "→ App-Icon einbauen"
ICON_PNG="$DIST/AppIcon.png"
swift "$ROOT/Scripts/generate_icon.swift" "$ICON_PNG"
sips -z 16 16     "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_PNG" "$RESOURCES_DIR/AppIcon.png"
rm -rf "$ICONSET"

echo "→ Ad-hoc signieren"
codesign --force --deep --sign - "$APP" >/dev/null

echo "→ DMG vorbereiten"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<'TXT'
Unarchive
Created by Shambhala222

1. Drag Unarchive onto Applications.
2. Open Unarchive once.
3. Unarchive → Settings to pick language, appearance and default formats.
4. File → Use Unarchive for Archives to open RAR/ZIP/7z on double-click.

Unpack: RAR, ZIP, 7z, TAR, GZ, BZ2, XZ, ISO, CAB, LHA and more.
Create: ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ.

RAR volumes (including encrypted RAR 5 / WinRAR 7) are unpacked with UnRAR.
Password-protected archives ask for a key.
Select multiple files and drag them into Finder.
TXT

echo "→ DMG nach Downloads schreiben"
rm -f "$DMG" "${DOWNLOADS}/Uncrate.dmg" "${DOWNLOADS}/Entpacker.dmg"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

xattr -cr "$DMG" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
touch "$DIST/.metadata_never_index"

if [[ -d "/Applications/${APP_NAME}.app" ]]; then
  if pgrep -x Unarchive >/dev/null 2>&1 || pgrep -f "/Applications/Unarchive.app/Contents/Helpers/unrar" >/dev/null 2>&1; then
    echo "→ Unarchive läuft gerade – Programme nicht ersetzen"
    echo "  Neue App liegt in: $APP"
  else
    echo "→ Vorhandene App in Programme ersetzen"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/${APP_NAME}.app"
    xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true
  fi
fi

echo
echo "Fertig."
echo "App:  $APP"
echo "DMG:  $DMG"
ls -lh "$APP" "$DMG"
