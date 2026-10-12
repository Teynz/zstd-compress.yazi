#!/bin/bash
P=/home/tester/play
umount "$P/dir_mnt/mnt" 2>/dev/null
rm -rf "$P" /home/tester/.local/share/Trash
mkdir -p "$P"/dir1/sub "$P"/dir_sock "$P"/dir_mnt/mnt "$P"/dir_unread
head -c 2000000 /tmp/claude-0/zt/mid.txt > "$P/a.txt"
printf 'spezial\n' > "$P/b'c \"d\" \$x.txt"
printf 'dash\n' > "$P/-lead.txt"
printf 'eins\n' > "$P/dir1/eins.txt"; printf 'geheim\n' > "$P/dir1/sub/geheim.txt"; chmod 600 "$P/dir1/sub/geheim.txt"
printf 'c\n' > "$P/c.txt"; printf 'old\n' | zstd -q -o "$P/c.txt.zst"
python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.bind('$P/dir_sock/s.sock')"
printf 'x\n' > "$P/dir_sock/x.txt"
printf 'u\n' > "$P/dir_unread/ok.txt"; printf 'n\n' > "$P/dir_unread/noread.txt"
ln -s a.txt "$P/link.txt"; mkfifo "$P/fifo"
cp /tmp/claude-0/zt/big.txt "$P/big.txt"
chown -R tester:tester "$P"; chmod 000 "$P/dir_unread/noread.txt"
mount -t tmpfs tmpfs "$P/dir_mnt/mnt" && echo m > "$P/dir_mnt/mnt/m.txt"
rm -rf /tmp/claude-0/pristine; mkdir -p /tmp/claude-0/pristine
cp -a "$P/a.txt" "$P/b'c \"d\" \$x.txt" "$P/-lead.txt" "$P/dir1" "$P/c.txt" /tmp/claude-0/pristine/
ls -la "$P"
