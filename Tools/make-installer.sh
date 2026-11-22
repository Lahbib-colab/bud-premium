#!/bin/bash
#
#  Fabrique l'installeur en un seul fichier à partir du dépôt.
#
#    ./Tools/make-installer.sh              → dist/Installer_BUD_Premium.command
#    ./Tools/make-installer.sh /autre/chemin.command
#
#  L'installeur produit écrit les sources dans
#  ~/Library/Application Support/BUD-Assistant/ puis appelle build.sh.
#  Toute la logique de compilation reste donc dans build.sh : ce script
#  ne fait que de l'emballage.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^let budVersion = "\(.*\)"/\1/p' "$REPO/Sources/BudCore.swift" | head -1)"
[ -n "$VERSION" ] || { echo "Version introuvable dans Sources/BudCore.swift" >&2; exit 1; }

OUT="${1:-$REPO/dist/Installer_BUD_Premium.command}"
mkdir -p "$(dirname "$OUT")"

# Un délimiteur qui n'apparaît dans aucun fichier embarqué.
guard() {
  if grep -qF "$1" "$2"; then
    echo "Le délimiteur $1 apparaît dans $2 : changez-le." >&2
    exit 1
  fi
}

emit() {   # $1 = fichier source, $2 = chemin de destination, $3 = délimiteur
  guard "$3" "$1"
  printf '\ncat << %s > "%s"\n' "'$3'" "$2"
  cat "$1"
  printf '%s\n' "$3"
}

{
cat <<HEAD
#!/bin/bash
set -e

SUPPORT_DIR="\$HOME/Library/Application Support/BUD-Assistant"
SRC_DIR="\$SUPPORT_DIR/src"
TOOLS_DIR="\$SUPPORT_DIR/tools"

echo "============================================================"
echo "   BUD Premium ${VERSION} — macOS 12 Monterey à Sequoia"
echo "============================================================"

mkdir -p "\$SRC_DIR" "\$TOOLS_DIR" "\$SUPPORT_DIR/agents"

# Sauvegarde de l'état avant toute écriture : une mise à jour ne doit
# jamais coûter les réglages ni les notes.
if [ -f "\$SUPPORT_DIR/state.json" ]; then
  cp "\$SUPPORT_DIR/state.json" "\$SUPPORT_DIR/state.backup-\$(date +%Y%m%d-%H%M%S).json"
  echo "Sauvegarde de state.json effectuée."
fi
HEAD

for f in "$REPO"/Sources/*.swift; do
  base="$(basename "$f")"
  tag="EOF_$(echo "$base" | tr 'a-z.' 'A-Z_' | tr -cd 'A-Z_')"
  emit "$f" "\$SRC_DIR/$base" "$tag"
done

emit "$REPO/Tools/MakeIcon.swift" "\$TOOLS_DIR/MakeIcon.swift" "EOF_MAKEICON_X9"
emit "$REPO/build.sh" "\$SUPPORT_DIR/build.sh" "EOF_BUDBUILD_7K2"

cat <<'MID'

chmod +x "$SUPPORT_DIR/build.sh"
MID

# ── Passerelle en ligne de commande pour les agents ──
emit "$REPO/Tools/bud-ask" "\$SUPPORT_DIR/bud-ask" "EOF_BUDASK_M4"

cat <<'TAIL'
chmod +x "$SUPPORT_DIR/bud-ask"

xattr -cr "$SUPPORT_DIR" 2>/dev/null || true

# Toute la compilation vit dans build.sh, partagé avec le dépôt.
bash "$SUPPORT_DIR/build.sh" install --src "$SRC_DIR" --tools "$TOOLS_DIR"

echo "Passerelle agents : \"$SUPPORT_DIR/bud-ask\" \"Titre\" \"Détail\" \"$PWD\""
TAIL
} > "$OUT"

chmod +x "$OUT"
bash -n "$OUT"
echo "Installeur $VERSION écrit : $OUT ($(grep -c '' "$OUT") lignes)"
