-- lua5.4 tests/unit.lua main.lua   (reine Funktionen, ohne Yazi)
local src = io.open(arg[1]):read("a")
local n
src, n = src:gsub(
	"return { entry = entry, setup = setup, version = VERSION }%s*$",
	"return { split_ext=split_ext, dirname=dirname, basename=basename, inside=inside, join=join, fmt_size=fmt_size, "
		.. "detect=detect, FMT=FMT, FORMATS=FORMATS, PRESETS=PRESETS, OPT=OPT, spec=spec, defaults=defaults, coerce=coerce, "
		.. "words=words, mountpoints=mountpoints, tail=tail, preset_values=preset_values, is_ours=is_ours }"
)
assert(n == 1, "return-Zeile nicht gefunden")
ya = { hash = function() return string.rep("a", 32) end, time = os.time }
local M = assert(load(src, "main.lua"))()
local fails = 0
local function eq(a, b, msg)
	if a ~= b then
		fails = fails + 1
		print("FAIL", msg, tostring(a), tostring(b))
	end
end
local function args(id, o, ctx)
	local full = M.defaults(M.FMT[id])
	for k, v in pairs(o or {}) do
		full[k] = v
	end
	return table.concat(M.FMT[id].pack(full, ctx or {}), " ")
end

-- Pfade
local s, e = M.split_ext("foo.pdf"); eq(s, "foo", "ext1"); eq(e, ".pdf", "ext1b")
s, e = M.split_ext("README"); eq(s, "README", "ext2"); eq(e, "", "ext2b")
s, e = M.split_ext(".bashrc"); eq(s, ".bashrc", "ext3"); eq(e, "", "ext3b")
s, e = M.split_ext("a.tar.gz"); eq(s, "a.tar", "ext4"); eq(e, ".gz", "ext4b")
eq(M.dirname("/home/paul/a.txt"), "/home/paul", "dn1"); eq(M.dirname("/a"), "/", "dn2")
eq(M.basename("/home/paul/a b.txt"), "a b.txt", "bn1"); eq(M.basename("/"), nil, "bn2")
eq(M.inside("/a/b", "/a"), true, "in1"); eq(M.inside("/ab", "/a"), false, "in2"); eq(M.inside("/x", "/"), true, "in4")
eq(M.join("/", "x"), "/x", "j1"); eq(M.join("/a", "x"), "/a/x", "j2")
eq(M.fmt_size(0), "0 B", "fs0"); eq(M.fmt_size(1536), "1.5 KiB", "fs1")
eq(#M.words("  a  b c "), 3, "words")
eq(M.is_ours("/x/.yazi-compress-0123abcdef.part"), true, "ours1"); eq(M.is_ours("/x/foo.part"), false, "ours2")
eq(M.is_ours("/run/user/1/yazi-compress-0123abcdef.err"), true, "ours3")

-- Kompressor-Argumente
eq(args("zst", { level = 19 }), "-q -c -19 -T0", "zst19")
eq(args("zst", { level = 22 }), "-q -c -22 --ultra -T4", "zst22")
eq(args("zst", { level = 22, threads = 2, long = "31" }, { size = 5 }), "-q -c -22 --ultra -T2 --long=31 --stream-size=5", "zst22l")
eq(args("zst", { level = -5 }), "-q -c --fast=5 -T0", "zstfast")
eq(args("xz", { level = 9, extreme = true, threads = 3 }), "-q -c -9 -T3 -e", "xz")
eq(args("lzma", { level = 6 }), "-q -c --format=lzma -6", "lzma")
eq(args("gz", { level = 9, threads = 4 }, { bin = "pigz" }), "-q -c -9 -p 4", "pigz")
eq(args("gz", { level = 9, threads = 4 }, { bin = "gzip" }), "-q -c -9", "gzip")
eq(args("7z", { level = 9, hide = true }, { password = true }), "-mx=9 -ms=on -mmt=on -m0=LZMA2 -mhe=on -snl", "7z")
eq(args("7z", { level = 0, hide = true, links = false }, {}), "-mx=0 -ms=on -mmt=on", "7z0")
eq(args("zip", { crypt = "ZipCrypto" }, { password = true }), "-mx=5 -mcu=on -mmt=on -mm=Deflate -mem=ZipCrypto -snl", "zip")

-- Preset "backwordscompability": nur Deflate, UTF-8, keine Links, keine Teilung
local bc
for _, p in ipairs(M.PRESETS) do
	bc = p.id == "backwordscompability" and p or bc
end
local o = M.preset_values(M.FMT.zip, bc, false)
eq(table.concat(M.FMT.zip.pack(o, {}), " "), "-mx=6 -mcu=on -mmt=on -mm=Deflate", "compat-args")
eq(o.split, "", "compat-split"); eq(o.winsafe, true, "compat-winsafe"); eq(o.crypt, "ZipCrypto", "compat-crypt")

-- Tasten: innerhalb eines Formats eindeutig, keine Kollision mit festen Formular-Tasten
local fixed = { f = 1, k = 1, a = 1, m = 1, o = 1, E = 1, T = 1, i = 1, D = 1, N = 1, v = 1, C = 1, P = 1, X = 1 }
for _, p in ipairs(M.PRESETS) do
	fixed[p.key] = 1
end
for _, f in ipairs(M.FORMATS) do
	local seen = {}
	for _, id in ipairs(f.opts) do
		local k = M.spec(f, id).key
		eq(seen[k] or fixed[k], nil, "key " .. f.id .. "." .. id)
		seen[k] = 1
		eq(M.defaults(f)[id] ~= nil, true, "default " .. f.id .. "." .. id)
	end
end

-- Archiv-Erkennung
local function det(name) local d = M.detect(name); return (d.fmt and d.fmt.id or "7z") .. "/" .. tostring(d.tar) .. "/" .. d.stem .. "/" .. tostring(d.known) end
eq(det("a.tar.zst"), "zst/true/a/true", "d1"); eq(det("a.tzst"), "zst/true/a/true", "d2")
eq(det("foo.pdf.zst"), "zst/false/foo.pdf/true", "d3"); eq(det("x.TAR.GZ"), "gz/true/x/true", "d4")
eq(det("x.tar"), "tar/true/x/true", "d5"); eq(det("x.zip"), "7z/nil/x/true", "d6")
eq(det("x.7z.001"), "7z/nil/x/true", "d7"); eq(det("x.7z.002"), "7z/nil/x/false", "d8")
eq(det("notes.txt"), "7z/nil/notes/false", "d9"); eq(det("a.tar.lzma"), "lzma/true/a/true", "d10")
eq(det(".zst"), "7z/nil/.zst/false", "d11")

-- gespeicherte Werte
eq(M.coerce("int", "99", { min = 1, max = 9, def = 6 }), 6, "c1"); eq(M.coerce("int", "7", { min = 1, max = 9, def = 6 }), 7, "c2")
eq(M.coerce("int", "x", { min = 1, max = 9, def = 6 }), 6, "c3"); eq(M.coerce("bool", "1"), true, "c4")
eq(M.coerce("choice", "nope", { values = { "a", "b" }, def = "a" }), "a", "c5"); eq(M.coerce("after", "rm -rf"), "keep", "c6")

-- Mountpunkte
local line = "36 35 98:0 / /mnt/my\\040disk rw - ext3 /dev/x rw"
local mp = line:match("^%S+ %S+ %S+ %S+ (%S+)"); mp = mp:gsub("\\(%d%d%d)", function(x) return string.char(tonumber(x, 8)) end)
eq(mp, "/mnt/my disk", "unesc")
print(fails == 0 and "ALL UNIT TESTS PASSED" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
