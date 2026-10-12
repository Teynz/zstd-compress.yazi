#!/usr/bin/env bash
# install.sh — zstd-compress.yazi v1.0.0 (2026-10-12)
# MODUS: SCHREIBEND — ändert ~/.config/yazi (keymap.toml, package.toml, plugins/)
# Kategorie C. Backups: ~/.config/yazi/backup-zstd-<TS>/ ; Rollback-Befehl am Ende.
set -uo pipefail
TS=$(date +%Y%m%d-%H%M%S)
CFG="${YAZI_CONFIG_HOME:-$HOME/.config/yazi}"
KM="$CFG/keymap.toml"
PKG="$CFG/package.toml"
DST="$CFG/plugins/zstd-compress.yazi"
BK="$CFG/backup-zstd-$TS"
REPO="Teynz/zstd-compress"
fail() { echo "[FAIL] $*"; exit 1; }
restore() { # Backups zurückspielen, dann abbrechen
  cp -a "$BK/keymap.toml" "$BK/package.toml" "$CFG/"
  if [ -e "$BK/zstd-compress.yazi.alt" ] && [ ! -e "$DST" ]; then
    mv "$BK/zstd-compress.yazi.alt" "$DST"
  fi
  fail "$1 – Backups zurückgespielt"
}

echo "== Vorbedingungen =="
for t in yazi ya zstd tar python3; do
  command -v "$t" >/dev/null || fail "$t fehlt → installieren (pacman -S $t)"
done
command -v gio >/dev/null || command -v trash-put >/dev/null \
  || fail "weder gio noch trash-put → pacman -S glib2 (oder trash-cli)"
command -v setpriv >/dev/null \
  || echo "[WARN] setpriv fehlt (util-linux): zstd überlebt dann ein Yazi-Ende"
[ -d "$CFG" ] || fail "$CFG fehlt"
touch "$KM" "$PKG" || fail "$KM / $PKG nicht schreibbar"
if grep -qE '^[[:space:]]*(prepend_keymap|append_keymap|keymap)[[:space:]]*=' "$KM"; then
  fail "keymap.toml nutzt Inline-Arrays (prepend_keymap = [...]); manuell eintragen"
fi
echo "[PASS] Vorbedingungen"

echo "== Backup → $BK =="
mkdir -p "$BK" && cp -a "$KM" "$PKG" "$BK/" || fail "Backup fehlgeschlagen"
if [ -e "$DST" ] && ! grep -q "$REPO" "$PKG"; then
  mv "$DST" "$BK/zstd-compress.yazi.alt" && echo "altes Plugin → $BK/"
fi

echo "== alte 'c z'-Bindings entfernen =="
python3 - "$KM" << 'PY'
import re, sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
cz = re.compile(r'on\s*=\s*\[\s*["\']c["\']\s*,\s*["\']z["\']\s*\]')
parts = re.split(r'(?m)^(?=\s*\[)', src)
keep, removed = [], 0
for part in parts:
    if part.lstrip().startswith("[[") and cz.search(part):
        removed += 1
        print("  entfernt:", " ".join(part.split())[:90])
    else:
        keep.append(part)
out = "".join(keep).rstrip("\n") + "\n"
out += ('\n[[mgr.prepend_keymap]]\non   = [ "c", "z" ]\n'
        'run  = "plugin zstd-compress"\ndesc = "mit zstd komprimieren"\n')
import tomllib
tomllib.loads(out)
open(p, "w", encoding="utf-8").write(out)
print(f"  {removed} alte(s) Binding(s) entfernt, neues eingetragen")
PY
[ $? -eq 0 ] || restore "keymap-Edit fehlgeschlagen"

echo "== Plugin installieren (ya pkg) =="
if grep -q "$REPO" "$PKG"; then
  # nur dieses Paket (andere, lokal gepatchte Plugins bleiben unberührt)
  ya pkg upgrade "$REPO" || restore "ya pkg upgrade fehlgeschlagen"
else
  ya pkg add "$REPO" || restore "ya pkg add fehlgeschlagen"
fi

echo "== Verifikation =="
ok=1
chk() { if eval "$2"; then echo "[PASS] $1"; else echo "[FAIL] $1"; ok=0; fi; }
chk "main.lua installiert" "[ -s '$DST/main.lua' ]"
chk "package.toml-Eintrag" "grep -q '$REPO' '$PKG'"
chk "genau 1x 'c z'" \
  "[ \"\$(grep -cE 'on *= *\\[ *\"c\" *, *\"z\" *\\]' '$KM')\" = 1 ]"
chk "keymap.toml gültig" "python3 -c 'import tomllib;tomllib.load(open(\"$KM\",\"rb\"))'"
echo
[ $ok = 1 ] && echo "FERTIG. Yazi neu starten, dann: c → z → 1-8." \
            || echo "FEHLER oben prüfen."
echo "Rollback: ya pkg delete $REPO; cp -a '$BK/keymap.toml' '$BK/package.toml' '$CFG/'"
