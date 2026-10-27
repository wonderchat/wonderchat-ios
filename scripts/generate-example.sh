#!/usr/bin/env bash
# Downloads a pinned XcodeGen into .tools/ (gitignored) and generates
# Example/WonderchatExample.xcodeproj from Example/project.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.46.0}"
TOOLS="$ROOT/.tools"
XCODEGEN="$TOOLS/xcodegen-$XCODEGEN_VERSION/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
  echo "Downloading XcodeGen $XCODEGEN_VERSION into .tools/"
  mkdir -p "$TOOLS"
  download="$(mktemp -d)"
  curl -fsSL -o "$download/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  unzip -q "$download/xcodegen.zip" -d "$download/out"
  rm -rf "$TOOLS/xcodegen-$XCODEGEN_VERSION"
  mv "$download/out/xcodegen" "$TOOLS/xcodegen-$XCODEGEN_VERSION"
  rm -rf "$download"
fi

"$XCODEGEN" generate --quiet --spec "$ROOT/Example/project.yml" --project "$ROOT/Example"
echo "Generated Example/WonderchatExample.xcodeproj"
