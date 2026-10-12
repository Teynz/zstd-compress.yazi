# test helpers (run as root, yazi runs as tester)
PLUG_SRC=/tmp/claude-0/ycfg/plugins/zstd-compress.yazi/main.lua
YCFG=/home/tester/ycfg
LOG=/home/tester/.local/state/yazi/yazi.log
k(){ for x in "$@"; do tmux send-keys -t y "$x"; sleep 0.45; done; }
cap(){ tmux capture-pane -p -t y | sed -e 's/[[:space:]]*$//'; }
ystart(){ # $1 = dir
  tmux kill-session -t y 2>/dev/null; sleep 0.3
  install -D -o tester -g tester -m 644 "$PLUG_SRC" "$YCFG/plugins/zstd-compress.yazi/main.lua"
  rm -f "$LOG"
  tmux new-session -d -s y -x 170 -y 45 "su tester -c \"env TERM=xterm-256color XDG_RUNTIME_DIR=/run/user/1001 YAZI_CONFIG_HOME=$YCFG YAZI_LOG=debug /tmp/yazi-src/target/debug/yazi '$1'\"; sleep 100000"
  sleep 2.5
}
plog(){ sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -a -iE "zstd|ERROR" | grep -v -e 7z -e by-label -e passthrough -e mime.local | cut -c1-300 | tail -${1:-8}; }
waitgone(){ # wait until no zstd/tar processes of tester, max $1 s
  for i in $(seq 1 $((${1:-30}*4))); do pgrep -u tester -x zstd >/dev/null || pgrep -u tester -x tar >/dev/null || return 0; sleep 0.25; done; return 1; }
tl(){ ls -la --time-style=+%H:%M:%S "$@"; }
ystart(){ # $1 = dir
  tmux kill-session -t y 2>/dev/null; sleep 0.3
  install -D -o tester -g tester -m 644 "$PLUG_SRC" "$YCFG/plugins/zstd-compress.yazi/main.lua"
  rm -f "$LOG"
  tmux new-session -d -s y -x 170 -y 45 "su tester -c \"env TERM=xterm-256color XDG_RUNTIME_DIR=/run/user/1001 YAZI_CONFIG_HOME=$YCFG YAZI_LOG=debug /tmp/yazi-src/target/debug/yazi --client-id 4242 '$1'\"; sleep 100000"
  sleep 2.5
}
ya_(){ su tester -c "env XDG_RUNTIME_DIR=/run/user/1001 /tmp/yazi-src/target/debug/ya emit-to 4242 $*"; sleep 0.4; }
hover(){ ya_ reveal "'$1'"; }
sel(){ for p in "$@"; do ya_ reveal "'$p'"; ya_ toggle --state=on; done; }
ya_(){ runuser -u tester -- env XDG_RUNTIME_DIR=/run/user/1001 /tmp/yazi-src/target/debug/ya emit-to 4242 "$@"; sleep 0.4; }
hover(){ ya_ reveal "$1"; }
sel(){ for p in "$@"; do ya_ reveal "$p"; ya_ toggle --state=on; done; }
sel(){ for p in "$@"; do ya_ reveal "$p"; sleep 0.6; ya_ toggle --state=on; sleep 0.3; done; }
