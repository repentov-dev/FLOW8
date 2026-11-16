#!/bin/bash
# FLOW8 — сборка без Xcode, нужны только Xcode Command Line Tools.
#   ./build.sh          — собрать build/FLOW8.app (Apple Silicon)
#   ./build.sh --install — собрать и скопировать в /Applications
#   ./build.sh --run     — собрать и запустить
set -e
cd "$(dirname "$0")"

APP="build/FLOW8.app"
VERSION="1.0.0"
ARCH="${ARCH:-arm64}"

step() { echo; echo "==> [$1/4] $2"; }
trap 'status=$?; if [ $status -ne 0 ]; then echo; echo "BUILD FAILED (exit code $status)." >&2; fi' EXIT

step 1 "Проверка инструментов"
if ! xcrun -f swiftc >/dev/null 2>&1; then
  echo "swiftc не найден. Установите Command Line Tools: xcode-select --install" >&2
  exit 1
fi
xcrun swiftc --version | head -1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -print0 | sort -z)

step 2 "Компиляция ($ARCH)"
mkdir -p .build
xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/clangcache" \
  "${SOURCES[@]}" \
  -o "$APP/Contents/MacOS/FLOW8"

step 3 "Ресурсы и подпись"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

step 4 "Готово"
echo "    $APP"

if [ "$1" = "--install" ] || [ "$2" = "--install" ]; then
  rm -rf "/Applications/FLOW8.app"
  cp -R "$APP" "/Applications/FLOW8.app"
  open "/Applications/FLOW8.app"
  echo "    Установлено в /Applications"
fi

if [ "$1" = "--run" ] || [ "$2" = "--run" ]; then
  open "$APP"
fi
