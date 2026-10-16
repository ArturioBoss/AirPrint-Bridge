#!/bin/bash
# Сборка «AirPrint Bridge.app» без Xcode (нужны Command Line Tools: xcode-select --install).
#
# Использование:
#   ./build-app.sh              собрать в ./build
#   ./build-app.sh --install    собрать и установить в /Applications
#   ./build-app.sh --dmg        собрать и упаковать в build/AirPrint-Bridge-<версия>.dmg
#
# Переменные окружения:
#   SIGN_ID    идентификатор подписи, например "Developer ID Application: Имя (TEAMID)".
#              По умолчанию "-" (ad-hoc, только для своего Mac).
#   UNIVERSAL  1 (по умолчанию) — arm64 + x86_64; 0 — только архитектура этого Mac.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AirPrint Bridge"
BUNDLE_ID="com.arturios.airprint-bridge"
DEVELOPER="ArturiOS"
VERSION="$(tr -d '[:space:]' < VERSION)"
SIGN_ID="${SIGN_ID:--}"
UNIVERSAL="${UNIVERSAL:-1}"
BUNDLE="build/$APP_NAME.app"

ARCH_ARGS=()
[ "$UNIVERSAL" = "1" ] && ARCH_ARGS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/AirPrintBridge"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/AirPrintBridge"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>AirPrintBridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- Только иконка в строке меню, без значка в Dock -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 $DEVELOPER</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AirPrint Bridge запрашивает пароль администратора, чтобы включить общий доступ к принтеру в CUPS.</string>
</dict>
</plist>
PLIST

if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$BUNDLE"
else
  # Hardened runtime + timestamp — обязательны для нотаризации
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$BUNDLE"
fi
codesign --verify --deep --strict "$BUNDLE"
echo "Собрано: $BUNDLE (версия $VERSION, подпись: $SIGN_ID)"

case "${1:-}" in
  --install)
    pkill -x AirPrintBridge 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$BUNDLE" "/Applications/"
    open "/Applications/$APP_NAME.app"
    echo "Установлено в /Applications и запущено."
    ;;
  --dmg)
    DMG="build/AirPrint-Bridge-$VERSION.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$BUNDLE" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    [ "$SIGN_ID" != "-" ] && codesign --force --sign "$SIGN_ID" "$DMG"
    echo "Образ: $DMG"
    ;;
esac
