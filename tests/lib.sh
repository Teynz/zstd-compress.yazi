# Sandbox-Helfer: als root ausführen, Yazi läuft als Benutzer "tester" in tmux.
# Nicht für den Produktivbetrieb. Voraussetzung: useradd -m tester; YB = Ordner mit yazi + ya.
YB=${YB:-/tmp/ybin/yazi-x86_64-unknown-linux-musl}
PLUG_SRC=${PLUG_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/main.lua}
YCFG=/home/tester/ycfg
TUID=$(id -u tester)
LOG=/home/tester/.local/state/yazi/yazi.log
ENVV="TERM=xterm-256color HOME=/home/tester XDG_RUNTIME_DIR=/run/user/$TUID YAZI_CONFIG_HOME=$YCFG YAZI_LOG=debug LANG=C.UTF-8"
k(){ for x in "$@"; do tmux send-keys -t y "$x"; sleep 0.45; done; }
cap(){ tmux capture-pane -p -t y | sed -e 's/[[:space:]]*$//'; }
ystart(){ # $1 = dir
  tmux kill-session -t y 2>/dev/null; sleep 0.3
  mkdir -p "/run/user/$TUID" && chown tester "/run/user/$TUID" && chmod 700 "/run/user/$TUID"
  install -D -o tester -g tester -m 644 "$PLUG_SRC" "$YCFG/plugins/zstd-compress.yazi/main.lua"
  cat > "$YCFG/keymap.toml" <<'KM'
[[mgr.prepend_keymap]]
on = [ "c", "z" ]
run = "plugin zstd-compress"
[[mgr.prepend_keymap]]
on = [ "c", "x" ]
run = "plugin zstd-compress extract"
[[mgr.prepend_keymap]]
on = [ "c", "t" ]
run = "plugin zstd-compress test"
[[mgr.prepend_keymap]]
on = [ "c", "b" ]
run = "plugin zstd-compress -- --preset=backwordscompability"
KM
  [ -f "$YCFG/init.lua" ] || : > "$YCFG/init.lua"
  chown -R tester:tester "$YCFG"; rm -f "$LOG"
  tmux new-session -d -s y -x 170 -y 50 "runuser -u tester -- env $ENVV $YB/yazi --client-id 4242 '$1'; sleep 100000"
  sleep 2.5
}
plog(){ sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -a -iE "compress|ERROR" | grep -v -e by-label -e passthrough -e mime.local | cut -c1-400 | tail -${1:-8}; }
busy(){ pgrep -u tester -x "zstd|tar|xz|gzip|pigz|bzip2|lz4|lzip|brotli|7z|7zz|du|sha256sum|gio" >/dev/null; }
waitgone(){ sleep 0.6; for i in $(seq 1 $((${1:-30}*4))); do busy || { sleep 0.5; busy || return 0; }; sleep 0.25; done; return 1; }
ya_(){ runuser -u tester -- env XDG_RUNTIME_DIR=/run/user/$TUID $YB/ya emit-to 4242 "$@"; sleep 0.4; }
hover(){ ya_ reveal "$1"; sleep 0.3; }
sel(){ for p in "$@"; do ya_ reveal "$p"; sleep 0.5; ya_ toggle --state=on; sleep 0.3; done; }
tl(){ ls -la --time-style=+%H:%M:%S "$@"; }
capb(){ cap | tail -n ${1:-20} | cut -c1-${2:-170}; }
