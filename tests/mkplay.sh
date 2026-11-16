#!/bin/bash
# baut die Sandbox /home/tester/play (als root)
mkdir -p /tmp/zc-test
P=/home/tester/play
umount "$P/dir_mnt/mnt" 2>/dev/null
rm -rf "$P" /home/tester/.local/share/Trash /home/tester/.local/state/yazi/zstd-compress
mkdir -p "$P"/dir1/sub "$P"/dir_sock "$P"/dir_mnt/mnt "$P"/dir_unread "$P"/win "$P"/out
[ -f /tmp/zc-test/mid.txt ] || { head -c 6000000 /dev/urandom | base64 > /tmp/zc-test/mid.txt; }
[ -f /tmp/zc-test/big.txt ] || { for i in $(seq 1 60); do cat /tmp/zc-test/mid.txt; done > /tmp/zc-test/big.txt; }
head -c 2000000 /tmp/zc-test/mid.txt > "$P/a.txt"
printf 'spezial\n' > "$P/b'c \"d\" \$x.txt"
printf 'dash\n' > "$P/-lead.txt"
printf 'stern\n' > "$P/st*rn?.txt"
printf 'umlaut\n' > "$P/Änderung ö.txt"
printf 'eins\n' > "$P/dir1/eins.txt"; printf 'geheim\n' > "$P/dir1/sub/geheim.txt"; chmod 600 "$P/dir1/sub/geheim.txt"
ln -s eins.txt "$P/dir1/link"; mkdir "$P/dir1/.git"; echo g > "$P/dir1/.git/HEAD"
printf 'c\n' > "$P/c.txt"; printf 'old\n' | zstd -q -o "$P/c.txt.zst"
python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.bind('$P/dir_sock/s.sock')"
printf 'x\n' > "$P/dir_sock/x.txt"
printf 'u\n' > "$P/dir_unread/ok.txt"; printf 'n\n' > "$P/dir_unread/noread.txt"
printf 'w\n' > "$P/win/a:b.txt"; printf 'w\n' > "$P/win/ok.txt"; printf 'w\n' > "$P/win/NUL.txt"
ln -s a.txt "$P/link.txt"; mkfifo "$P/fifo"
cp /tmp/zc-test/big.txt "$P/big.txt"
chown -R tester:tester "$P"; chmod 000 "$P/dir_unread/noread.txt"
mount -t tmpfs tmpfs "$P/dir_mnt/mnt" 2>/dev/null && echo m > "$P/dir_mnt/mnt/m.txt"
rm -rf /tmp/zc-test/pristine; mkdir -p /tmp/zc-test/pristine
cp -a "$P/a.txt" "$P/dir1" "$P/c.txt" /tmp/zc-test/pristine/
