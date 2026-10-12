local src = io.open(arg[1]):read("a")
src = src:gsub("return { entry = entry, version = VERSION }%s*$",
  "return { split_ext=split_ext, dirname=dirname, basename=basename, inside=inside, join=join, fmt_size=fmt_size, level_args=level_args, level_label=level_label, mountpoints=mountpoints, tail=tail }")
ya = { hash = function(s) return string.rep("a", 32) end, time = os.time }
local M = assert(load(src, "main.lua"))()
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL", msg, tostring(a), tostring(b)) end end
local s, e = M.split_ext("foo.pdf"); eq(s, "foo", "ext1"); eq(e, ".pdf", "ext1b")
s, e = M.split_ext("README"); eq(s, "README", "ext2"); eq(e, "", "ext2b")
s, e = M.split_ext(".bashrc"); eq(s, ".bashrc", "ext3"); eq(e, "", "ext3b")
s, e = M.split_ext("a.tar.gz"); eq(s, "a.tar", "ext4"); eq(e, ".gz", "ext4b")
s, e = M.split_ext("weird."); eq(s, "weird.", "ext5"); eq(e, "", "ext5b")
s, e = M.split_ext(".config.bak"); eq(s, ".config", "ext6"); eq(e, ".bak", "ext6b")
eq(M.dirname("/home/paul/a.txt"), "/home/paul", "dn1"); eq(M.dirname("/a"), "/", "dn2")
eq(M.basename("/home/paul/a b.txt"), "a b.txt", "bn1"); eq(M.basename("/"), nil, "bn2")
eq(M.inside("/a/b", "/a"), true, "in1"); eq(M.inside("/ab", "/a"), false, "in2"); eq(M.inside("/a", "/a"), true, "in3")
eq(M.inside("/x", "/"), true, "in4")
eq(M.join("/", "x"), "/x", "j1"); eq(M.join("/a", "x"), "/a/x", "j2")
eq(M.fmt_size(0), "0 B", "fs0"); eq(M.fmt_size(1536), "1.5 KiB", "fs1"); eq(M.fmt_size(5*1024^3), "5.0 GiB", "fs2")
eq(table.concat(M.level_args(19), " "), "-q -19 -T0", "la1"); eq(table.concat(M.level_args(22), " "), "-q --ultra -22 -T4", "la2")
eq(M.level_label(22), "Stufe 8 (-22)", "ll")
local mps = M.mountpoints(); print("mountpoints:", #mps, mps[1])
-- unescape test
local line = "36 35 98:0 / /mnt/my\\040disk rw - ext3 /dev/x rw"
local mp = line:match("^%S+ %S+ %S+ %S+ (%S+)"); mp = mp:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end)
eq(mp, "/mnt/my disk", "unesc")
print(fails == 0 and "ALL UNIT TESTS PASSED" or ("FAILURES: " .. fails))
