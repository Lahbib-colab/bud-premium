#!/bin/bash
#
#  Fabrique l'installeur en un seul fichier à partir du dépôt.
#
#  LC_ALL=C d'abord, et ce n'est pas une précaution de style.
#  L'ordre d'expansion d'un motif comme Art/*.png suit la collation de
#  la locale : en C, les majuscules passent avant les minuscules, et
#  « bud-w-U.png » précède « bud-w-dotL.png ». En en_US.UTF-8, qui est
#  la locale par défaut de macOS, le tri ignore la casse et l'ordre
#  s'inverse. L'installeur régénéré sur le CI ne correspondait donc plus
#  à celui engagé depuis Linux, alors que son contenu était identique —
#  seules les sections avaient changé de place.
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
export LC_ALL=C

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
ART_DIR="\$SUPPORT_DIR/art"

echo "============================================================"
echo "   BUD Premium ${VERSION} — macOS 12 Monterey à Sequoia"
echo "============================================================"

mkdir -p "\$SRC_DIR" "\$TOOLS_DIR" "\$SUPPORT_DIR/agents" "\$ART_DIR"

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

# Les illustrations sont binaires : elles passent en base64, seule forme
# qui traverse un script shell sans se faire abîmer par un octet nul ou
# une fin de ligne réinterprétée.
#
# « base64 -D » et non « -d » : Monterey embarque la version BSD, qui ne
# connaît que -D ; les macOS récents acceptent les deux. -D est donc la
# seule option qui décode de Monterey à Sequoia.
for a in "$REPO"/Art/*.png "$REPO"/Art/*.wav; do
  [ -f "$a" ] || continue
  n="$(basename "$a")"
  printf '\nbase64 -D > "%s" << %s\n' "\$ART_DIR/$n" "'EOF_BUDART_9X4'"
  # « base64 < fichier » et non « base64 fichier » : la version BSD de
  # macOS, où ce script tourne aussi, ne prend pas de nom de fichier en
  # argument. Et le repliage est imposé plutôt que laissé au défaut, qui
  # diffère d'une plateforme à l'autre — sinon l'installeur régénéré sur
  # macOS ne correspond plus à celui engagé depuis Linux.
  # La substitution mange les sauts de ligne de fin, printf en remet
  # exactement un : sans cela le délimiteur se collait à la dernière
  # ligne de base64 et le heredoc ne se fermait jamais.
  printf '%s\n' "$(openssl base64 -A < "$a" | fold -w 76)"
  printf 'EOF_BUDART_9X4\n'
done

cat <<'MID'

chmod +x "$SUPPORT_DIR/build.sh"
MID

# ── Passerelle en ligne de commande pour les agents ──
emit "$REPO/Tools/bud-ask" "\$SUPPORT_DIR/bud-ask" "EOF_BUDASK_M4"

cat <<'TAIL'
chmod +x "$SUPPORT_DIR/bud-ask"

xattr -cr "$SUPPORT_DIR" 2>/dev/null || true

# Toute la compilation vit dans build.sh, partagé avec le dépôt.
bash "$SUPPORT_DIR/build.sh" install --src "$SRC_DIR" --tools "$TOOLS_DIR" --art "$ART_DIR"

echo "Passerelle agents : \"$SUPPORT_DIR/bud-ask\" \"Titre\" \"Détail\" \"$PWD\""
TAIL
} > "$OUT"

chmod +x "$OUT"
bash -n "$OUT"
echo "Installeur $VERSION écrit : $OUT ($(grep -c '' "$OUT") lignes)"
