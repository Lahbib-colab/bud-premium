#!/bin/bash
#
#  BUD Premium — compilation et installation
#
#  Usage :
#    ./build.sh            compile et installe dans ~/Applications, puis lance
#    ./build.sh check      compile seulement, sans rien installer (utilisé par la CI)
#    ./build.sh install    comme sans argument
#
#  Options :
#    --src DIR     dossier des sources Swift      (défaut : ./Sources)
#    --tools DIR   dossier des outils annexes     (défaut : ./Tools)
#    --app DIR     paquet .app à produire         (défaut : ~/Applications/BUD.app)
#    --no-open     ne pas lancer l'application à la fin
#    --universal   binaire pour arm64 ET x86_64, fusionné par lipo
#                  (ce que produit la CI : la machine GitHub est en
#                   arm64, mais l'application doit tourner sur Intel)
#
#  Ce fichier est le seul endroit où vit la logique de compilation.
#  L'installeur en un seul fichier (dist/) embarque les sources puis
#  appelle ce script : il n'y a donc rien à tenir en double.
#
set -euo pipefail

MODE="install"
UNIVERSAL=0
SRC_DIR=""
TOOLS_DIR=""
APP_DIR="$HOME/Applications/BUD.app"
DO_OPEN=1

while [ $# -gt 0 ]; do
  case "$1" in
    check|install) MODE="$1"; shift ;;
    --src)   SRC_DIR="$2"; shift 2 ;;
    --tools) TOOLS_DIR="$2"; shift 2 ;;
    --app)   APP_DIR="$2"; shift 2 ;;
    --no-open) DO_OPEN=0; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "$SRC_DIR" ]   || SRC_DIR="$HERE/Sources"
[ -n "$TOOLS_DIR" ] || TOOLS_DIR="$HERE/Tools"

if [ ! -d "$SRC_DIR" ]; then
  echo "Sources introuvables : $SRC_DIR" >&2
  exit 1
fi

ARCH="$(uname -m)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo inconnue)"
VERSION="$(sed -n 's/^let budVersion = "\(.*\)"/\1/p' "$SRC_DIR/BudCore.swift" | head -1)"
[ -n "$VERSION" ] || VERSION="0.0"

# ─────────────────────────────────────────────────────────────────
#  Chaîne d'outils
#
#  swiftc est TOUJOURS appelé par xcrun, jamais par son chemin
#  résolu : c'est xcrun qui positionne SDKROOT. Sans lui, le
#  compilateur ne trouve pas la bibliothèque standard et échoue sur
#  « unable to load standard library ».
# ─────────────────────────────────────────────────────────────────

unset TOOLCHAINS || true          # une chaîne tierce sélectionnée fausserait tout

SWIFT_VIA="xcrun"
run_swiftc() {
  if [ "$SWIFT_VIA" = "plain" ]; then
    command swiftc "$@"
  else
    xcrun --sdk macosx swiftc "$@"
  fi
}

sdk_version() { xcrun --show-sdk-version 2>/dev/null || echo 0; }

if ! command -v swiftc >/dev/null 2>&1 && ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc est introuvable. Installez les outils : xcode-select --install" >&2
  exit 1
fi

SDKVER="$(sdk_version)"
SDKMAJ="${SDKVER%%.*}"
[ -n "$SDKMAJ" ] || SDKMAJ=0

# Outils antérieurs à Big Sur mais Xcode complet présent : on bascule
# dessus pour cette exécution, sans sudo ni modification du système.
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null && [ "$SDKMAJ" -lt 11 ] 2>/dev/null; then
  for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$X/Contents/Developer" ]; then
      export DEVELOPER_DIR="$X/Contents/Developer"
      NEW="$(sdk_version)"; NEWMAJ="${NEW%%.*}"
      if [ "${NEWMAJ:-0}" -ge 11 ] 2>/dev/null; then
        SDKVER="$NEW"; SDKMAJ="$NEWMAJ"
        echo "Outils de ligne de commande trop anciens : bascule sur $X."
        break
      fi
      unset DEVELOPER_DIR
    fi
  done
fi

SDKPATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "$SDKPATH" ] && export SDKROOT="$SDKPATH"

echo "BUD Premium $VERSION — macOS ${OSVER} · ${ARCH}"
echo "Outils     : $(xcode-select -p 2>/dev/null || echo inconnu)"
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null; then
  echo "SDK macOS  : $SDKVER"
else
  echo "SDK macOS  : illisible (xcrun muet)"
fi

# Un SDK à 0 veut dire « illisible », pas « ancien » : seul un numéro
# réellement antérieur à 11 justifie ce verdict.
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null && [ "$SDKMAJ" -lt 11 ] 2>/dev/null; then
  cat <<'DIAG' >&2

────────────────────────────────────────────────────────────────
  Vos outils de développement sont antérieurs à macOS 11, alors
  que BUD a besoin d'API apparues avec Big Sur.

    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --install

  Si Xcode complet est installé :

    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
────────────────────────────────────────────────────────────────

DIAG
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
#  Cible de déploiement
#
#  Les chaînes récentes écrivent « macos12.0 », les anciennes
#  « macosx12.0 ». On sonde pour de vrai plutôt que de supposer.
# ─────────────────────────────────────────────────────────────────

BUILD_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BUILD_TMP"; }
trap cleanup EXIT
PROBE="$BUILD_TMP/budprobe.swift"
echo 'public let budProbe = 1' > "$PROBE"

probe_compile() {
  if [ -n "${1:-}" ]; then
    run_swiftc -target "$1" -typecheck "$PROBE" >/dev/null 2>&1
  else
    run_swiftc -typecheck "$PROBE" >/dev/null 2>&1
  fi
}

if ! probe_compile ""; then
  # xcrun peut être en cause alors que le swiftc du PATH fonctionne.
  SWIFT_VIA="plain"
  if probe_compile ""; then
    echo "xcrun indisponible : utilisation directe de swiftc."
  else
    SWIFT_VIA="xcrun"
  fi
fi

if ! probe_compile ""; then
  RESCUED=""
  for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$X/Contents/Developer" ]; then
      export DEVELOPER_DIR="$X/Contents/Developer"
      SDKPATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
      [ -n "$SDKPATH" ] && export SDKROOT="$SDKPATH"
      if probe_compile ""; then
        RESCUED="$X"
        echo "Chaîne d'outils inutilisable : bascule sur $X."
        break
      fi
    fi
  done
  if [ -z "$RESCUED" ]; then
    cat <<'DIAG' >&2

────────────────────────────────────────────────────────────────
  Le compilateur Swift est présent mais ne trouve pas sa
  bibliothèque standard. L'installation des outils est incomplète.

    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --install

  Vérification :

    echo 'print(1)' > /tmp/t.swift && xcrun swiftc -typecheck /tmp/t.swift
────────────────────────────────────────────────────────────────

DIAG
    exit 1
  fi
fi

# Quelle orthographe de cible pour une architecture donnée ?
target_for() {
  local a="$1"
  local t
  for t in "${a}-apple-macos12.0" "${a}-apple-macosx12.0"; do
    if probe_compile "$t"; then echo "$t"; return 0; fi
  done
  echo ""
}

TARGET="$(target_for "$ARCH")"
if [ -n "$TARGET" ]; then
  echo "Cible      : $TARGET"
else
  export MACOSX_DEPLOYMENT_TARGET=12.0
  echo "Cible      : par défaut du SDK, MACOSX_DEPLOYMENT_TARGET=12.0"
fi

FRAMEWORKS=(-framework Cocoa -framework IOKit -framework Carbon
            -framework Security -framework Network -framework CoreImage
            -framework Speech -framework AVFoundation)

# ─────────────────────────────────────────────────────────────────
#  Compilation
# ─────────────────────────────────────────────────────────────────

if [ "$MODE" = "check" ]; then
  OUT="$BUILD_TMP/BUD"
  echo "Compilation de contrôle…"
  # shellcheck disable=SC2086
  run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
    "$SRC_DIR"/*.swift "${FRAMEWORKS[@]}" -o "$OUT"
  echo "Compilation du générateur d'icône…"
  run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
    "$TOOLS_DIR/MakeIcon.swift" -framework Cocoa -o "$BUILD_TMP/budicon"
  echo "BUD Premium $VERSION compile."
  exit 0
fi

pkill -x BUD 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN="$APP_DIR/Contents/MacOS/BUD"

if [ "$UNIVERSAL" -eq 1 ]; then
  # Le SDK macOS porte les deux tranches : on compile chaque
  # architecture depuis la même machine, puis lipo les réunit.
  echo "Compilation universelle (arm64 + x86_64)…"
  SLICES=()
  for A in arm64 x86_64; do
    T="$(target_for "$A")"
    if [ -z "$T" ]; then
      echo "Cible introuvable pour $A : ce SDK ne sait pas compiler cette architecture." >&2
      exit 1
    fi
    echo "  · $T"
    # shellcheck disable=SC2086
    run_swiftc -O -suppress-warnings -swift-version 5 -target "$T" \
      "$SRC_DIR"/*.swift "${FRAMEWORKS[@]}" -o "$BUILD_TMP/BUD-$A"
    SLICES+=("$BUILD_TMP/BUD-$A")
  done
  lipo -create "${SLICES[@]}" -output "$BIN"
  echo "Binaire universel : $(lipo -archs "$BIN")"
else
  echo "Compilation native…"
  # shellcheck disable=SC2086
  run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
    "$SRC_DIR"/*.swift "${FRAMEWORKS[@]}" -o "$BIN"
fi

# ── Icône ──
if [ -f "$TOOLS_DIR/MakeIcon.swift" ]; then
  TMPI="$BUILD_TMP/icon"; mkdir -p "$TMPI"
  if run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
       "$TOOLS_DIR/MakeIcon.swift" -framework Cocoa -o "$TMPI/budicon" 2>/dev/null; then
    "$TMPI/budicon" "$TMPI/BUD.iconset" >/dev/null 2>&1 || true
    if [ -d "$TMPI/BUD.iconset" ]; then
      iconutil -c icns "$TMPI/BUD.iconset" -o "$APP_DIR/Contents/Resources/BUD.icns" 2>/dev/null \
        && echo "Icône créée." || echo "iconutil indisponible, icône ignorée."
    fi
  else
    echo "Icône non générée."
  fi
fi

# ── Info.plist ──
#  ATTENTION : seules CFBundleShortVersionString et CFBundleVersion
#  suivent la version. LSMinimumSystemVersion doit RESTER 12.0, sinon
#  macOS refuse de lancer l'application (erreur -10825).
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>BUD</string>
  <key>CFBundleIconFile</key>
  <string>BUD</string>
  <key>CFBundleIconName</key>
  <string>BUD</string>
  <key>CFBundleIdentifier</key>
  <string>local.lahbib.bud.assistant.monterey</string>
  <key>CFBundleName</key>
  <string>BUD Premium</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>BUD utilise les événements système pour piloter Mail, la musique et l'apparence.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>BUD range les fichiers que vous déposez sur le notch.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>BUD range les fichiers que vous déposez sur le notch.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>BUD analyse les fichiers téléchargés et range ceux que vous déposez.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>BUD affiche et éjecte vos disques externes.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>BUD écoute le microphone uniquement pendant que vous tenez la dictée ouverte, et la reconnaissance se fait sur votre Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>BUD transforme votre parole en texte sur l'appareil. Si ce Mac ne sait pas le faire hors ligne, BUD refuse la dictée plutôt que d'envoyer votre voix sur le réseau.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR" 2>/dev/null || true

# ── Signature ad hoc ──
#  Obligatoire pour exécuter du arm64 : remplacer le binaire d'un
#  paquet signé invalide la signature et macOS tue l'application.
if codesign --force --sign - "$APP_DIR" 2>/dev/null; then
  echo "Signature ad hoc apposée."
else
  echo "Signature ad hoc impossible (sans effet sur Intel)."
fi

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP_DIR" >/dev/null 2>&1 || true

echo ""
echo "BUD Premium $VERSION installé dans $APP_DIR"
[ "$DO_OPEN" -eq 1 ] && open "$APP_DIR"
exit 0
