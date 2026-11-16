#!/bin/bash
# Regressionstest in einer echten Yazi-Instanz (tmux). Als root: tests/run.sh
# Prüft jedes Format (Datei + Ordner) gegen die Originale, dazu Entpacken,
# Passwort, Teilen, Presets, Abbruch und die Fehlerfälle.
cd "$(dirname "$0")" && . ./lib.sh
P=/home/tester/play; T=/tmp/zc-test; pass=0; fail=0
ok(){ if eval "$2" >/dev/null 2>&1 </dev/null; then pass=$((pass+1)); echo "[PASS] $1"; else fail=$((fail+1)); echo "[FAIL] $1"; fi; }
V=$(mktemp -d)
fresh(){ ./mkplay.sh >/dev/null 2>&1; ystart $P; }
same_dir(){ diff -r --no-dereference $T/pristine/dir1 "$1" </dev/null; }
clr(){ tmux send-keys -t y C-u; }

lua5.4 unit.lua ../main.lua | tail -1
fresh
declare -A DEC=( [zst]="zstd -dc" [xz]="xz -dc" [lzma]="xz -dc" [gz]="gzip -dc" [bz2]="bzip2 -dc" [lz4]="lz4 -dc" [br]="brotli -dc" [lz]="lzip -dc" )
declare -A KEY=( [zst]=z [xz]=x [lzma]=l [gz]=g [bz2]=b [lz4]=4 [br]=r [lz]=i )
for f in zst xz lzma gz bz2 lz4 br lz; do
  command -v ${DEC[$f]%% *} >/dev/null || { echo "[SKIP] $f"; continue; }
  hover $P/a.txt; k c z f ${KEY[$f]} Enter; waitgone 30
  hover $P/dir1; k c z Enter; waitgone 30
  ok "$f Datei" "${DEC[$f]} $P/a.txt.$f | cmp - $T/pristine/a.txt"
  mkdir -p $V/$f; ok "$f Ordner" "${DEC[$f]} $P/dir1.tar.$f | tar -x -C $V/$f && same_dir $V/$f/dir1"
done
for f in t 7 p; do hover $P/a.txt; k c z f $f Enter; waitgone 30; hover $P/dir1; k c z Enter; waitgone 30; done
ok "tar" "mkdir -p $V/tar && tar -xf $P/dir1.tar -C $V/tar && same_dir $V/tar/dir1"
ok "7z" "7z x -y -bso0 -bsp0 -o$V/7z $P/dir1.7z && same_dir $V/7z/dir1"
ok "zip" "mkdir -p $V/zip && (cd $V/zip && unzip -oq $P/dir1.zip) && same_dir $V/zip/dir1"
ok "Dateiname/-rechte/mtime" "[ $P/a.txt.zst -ot $P/a.7z ] && [ \$(stat -c %a $P/a.txt.zst) = 644 ]"

# alles wieder entpacken (nach out/)
sel $(ls -d $P/dir1.* $P/a.* | grep -v 'a.txt$'); k c x o; clr; k $P/out Enter Enter; waitgone 90; sleep 1
n=0; for d in $P/out/dir1*; do same_dir "$d" >/dev/null && n=$((n+1)); done; m=0; for x in $P/out/a*; do cmp -s "$x" $T/pristine/a.txt && m=$((m+1)); done
ok "Entpacken: $n Ordner, $m Dateien korrekt" "[ $n -ge 9 ] && [ $n = $m ]"

fresh
hover $P/dir1; k c z f 7 h k; k g e h Enter; k g e h Enter Enter; waitgone 20
ok "7z Passwort + Namen verschlüsselt" "7z t -pgeh -bso0 -bsp0 $P/dir1.7z && ! 7z l -pfalsch $P/dir1.7z"
hover $P/dir1.7z; k c x Enter; sleep 1.5; k f a l s c h Enter; sleep 1.5; k g e h Enter; waitgone 20
ok "Entpacken mit Passwort (erst falsch, dann richtig)" "same_dir $P/dir1_1"
hover $P/big.txt; k c z h l; clr; k 1 Enter r; clr; k 1 0 0 m Enter Enter; waitgone 180
ok "Teilen in 100m-Stücke" "[ -s $P/big.7z.001 ] && [ -s $P/big.7z.002 ] && 7z t -bso0 -bsp0 $P/big.7z.001"
k c z r; clr; k Enter Escape

hover $P/win; k c b; sleep 1.5; ok "Preset per --preset: Windows-Namen-Warnung" "cap | grep -q a:b.txt"; k y; waitgone 10
ok "backwordscompability: zip, nur Store/Deflate, lesbar mit unzip + python" "unzip -tq $P/win.zip && python3 -c \"
import zipfile,sys
z=zipfile.ZipFile('$P/win.zip'); sys.exit(0 if all(i.compress_type in (0,8) and not i.flag_bits & 1 for i in z.infolist()) else 1)\""

sel $P/a.txt $P/dir1 $P/link.txt $P/fifo; k c z f z a p Enter s; clr; k a l l e Enter; waitgone 20
ok "ein gemeinsames Archiv (inkl. Link + FIFO) + Papierkorb" "[ ! -e $P/a.txt ] && [ ! -e $P/dir1 ] && [ ! -e $P/fifo ] \
  && [ \$(tar --zstd -tf $P/alle.tar.zst | grep -c .) -ge 9 ] && ls /home/tester/.local/share/Trash/files/a.txt"

for d in dir_unread dir_mnt dir_sock; do hover $P/$d; k c z Enter; waitgone 10; done; sleep 1
ok "unlesbare Datei → Fehler, keine Reste" "[ ! -e $P/dir_unread.tar.zst ] && [ -d $P/dir_unread ]"
mountpoint -q $P/dir_mnt/mnt && ok "Mountpunkt → abgelehnt" "[ ! -e $P/dir_mnt.tar.zst ]"
ok "Socket → Archiv ja, Original bleibt" "[ -s $P/dir_sock.tar.zst ] && [ -d $P/dir_sock ]"
k c z a b Escape

hover $P/big.txt; k c z f x l; clr; k 9 Enter Enter; sleep 3; ok "Temp-Datei während der Arbeit" "ls -a $P | grep -q yazi-compress"
k w; sleep 0.5; ok "Fortschritt im Task-Manager" "cap | grep -qE '[0-9]+%'"; k x x x x x; sleep 2; k Escape
ok "Abbruch: Prozess weg, Temp weg, Original da" "! pgrep -u tester -x xz && ! ls -a $P | grep -q yazi-compress && [ -s $P/big.txt ]"

echo; echo "$pass bestanden, $fail fehlgeschlagen"; tmux kill-session -t y 2>/dev/null; [ $fail = 0 ]
