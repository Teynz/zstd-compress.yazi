--- @since 26.9.1
--- @sync entry

--[[
zstd-compress.yazi — v2.0.0 (2026-11-16)

Packen, Entpacken und Testen von Archiven als abbrechbare Yazi-Task
(Fortschritt im Task-Manager `w`, blockiert die UI nie).

  plugin zstd-compress                    → Formular „Komprimieren“
  plugin zstd-compress extract            → Formular „Entpacken“
  plugin zstd-compress test               → Archive nur prüfen
  plugin zstd-compress -- --preset=NAME   → Preset sofort starten

Aufbau dieser Datei (von oben nach unten):
  1. Einstellungen, Optionen, FORMATE, PRESETS   ← hier erweitert man das Plugin
  2. Hilfsfunktionen
  3. Prozess-Steuerung (Pipelines, Abbruch, Aufräumen)
  4. Dateisystem (Namen reservieren, Papierkorb, Größen)
  5. Jobs: packen / entpacken / testen
  6. Gespeicherte Einstellungen + Presets
  7. Oberfläche (Formulare)
  8. Ausführung als Task, Einstieg

Ein Format ist nur ein Tabelleneintrag: Der Ablauf ist für alle gleich,
ausgetauscht werden allein die Befehle.

  Stream-Formate (zstd, xz, gzip …):  Datei  →  kompressor < datei > archiv
                                      Ordner →  tar | kompressor > archiv
  7-Zip-Formate (7z, zip):            7z a archiv quellen…

Ablauf je Archiv (unverändert seit v1):
  1. Ausgabe in versteckte Temp-Datei .yazi-compress-<id>.part im Zielordner
  2. Integritätstest (vollständiges Dekomprimieren bzw. `7z t`)
  3. Zielname reservieren (nie überschreiben → _1, _2 …) + atomarer Rename
  4. je nach Wahl: Original behalten / in den Papierkorb / endgültig löschen —
     nur wenn 1–3 fehlerfrei waren UND kein Werkzeug etwas gemeldet hat
  Abbruch im Task-Manager oder Fehler → Temp-Datei weg, Original unverändert.
]]

local VERSION = "2.0.0"

-- ════════════════════════════ 1. Einstellungen ═════════════════════════════

-- per require("zstd-compress"):setup { … } überschreibbar
local CFG = {
	max_parallel = 2, -- gleichzeitige Jobs über alle Tasks
	max_heavy = 1, -- davon höchstens so viele speicherhungrige (zstd ≥ 20, --long ≥ 30, xz -9)
}

local POLL = 0.25 -- Sekunden zwischen Status-/Abbruch-Prüfungen
local TMP_PREFIX = ".yazi-compress-"
local TMP_SUFFIX = ".part"
local TMP_GLOB = ".yazi-compress-*.part*" -- eigene Temp-Dateien nie mitpacken
local TAR_CP = 100 -- tar meldet alle 100 Records (= 1 024 000 Byte) Fortschritt
local TAR_RECORD = 10240

-- ── Optionen ──
-- Jede Option erscheint im Formular als eine Zeile: Taste, Beschriftung, Wert.
-- type: "int" (min/max), "bool", "choice" (values), "text"
-- Formate können min/max/def/values/hint per `over` anpassen.
local OPT = {
	level = { key = "l", label = "Stufe", type = "int" },
	threads = { key = "t", label = "Threads", type = "int", min = 0, max = 256, def = 0, zero = "automatisch" },
	long = {
		key = "w",
		label = "Long-Range (--long)",
		type = "choice",
		def = "aus",
		values = { "aus", "27", "28", "29", "30", "31" },
		hint = "Fenster 2^n Byte; 27 = 128 MiB, 31 = 2 GiB",
	},
	extreme = { key = "e", label = "Extrem (-e)", type = "bool", def = false },
	method = { key = "c", label = "Verfahren", type = "choice" },
	solid = { key = "s", label = "Solid-Archiv", type = "bool", def = true },
	crypt = {
		key = "g",
		label = "Verschlüsselung",
		type = "choice",
		def = "AES256",
		values = { "AES256", "ZipCrypto" },
		hint = "ZipCrypto: unsicher, aber überall lesbar",
	},
	hide = { key = "h", label = "Dateinamen verschlüsseln", type = "bool", def = false },
	links = { key = "y", label = "Symlinks als Links", type = "bool", def = true },
	winsafe = { key = "u", label = "Windows-Namen prüfen", type = "bool", def = false },
	split = { key = "r", label = "Teilen in Stücke", type = "text", def = "", hint = "z. B. 100m, 4g – leer = nicht teilen" },
	extra = { key = "x", label = "Zusatz-Argumente", type = "text", def = "", hint = "durch Leerzeichen getrennt" },
}

local function add(list, ...)
	for _, x in ipairs { ... } do
		list[#list + 1] = x
	end
	return list
end

-- ── Formate ──
-- kind = "stream": `bin` liest stdin, schreibt stdout.  pack(o, ctx) → Argumente,
--                  unpack = Argumente zum Dekomprimieren.  bin = nil → reines tar.
-- kind = "7z":     Archiv über 7-Zip (`typ` = -t…).      pack(o, ctx) → Schalter.
-- o   = Optionswerte dieses Formats, ctx = { size, bin, password }
-- ext = Endung, tars = Kurzformen für tar+Format, heavy(o) = braucht viel RAM
local FORMATS = {
	{
		id = "zst",
		key = "z",
		name = "Zstandard",
		ext = ".zst",
		tars = { ".tzst" },
		kind = "stream",
		bin = { "zstd" },
		opts = { "level", "threads", "long", "extra" },
		over = { level = { min = -7, max = 22, def = 3, hint = "-7 … 22; ab 20 automatisch --ultra; negativ = --fast" } },
		pack = function(o, ctx)
			local a = { "-q", "-c" }
			if o.level < 0 then
				add(a, "--fast=" .. -o.level)
			else
				add(a, "-" .. o.level)
			end
			if o.level > 19 then
				add(a, "--ultra")
			end
			-- Stufe ≥ 20: ca. 0,8 GiB RAM pro Thread → automatisch nur 4 Threads
			add(a, "-T" .. (o.threads > 0 and o.threads or (o.level > 19 and 4 or 0)))
			if o.long ~= "aus" then
				add(a, "--long=" .. o.long)
			end
			if ctx.size and ctx.size > 0 then
				add(a, "--stream-size=" .. ctx.size) -- Größe im Header, passendes Fenster
			end
			return a
		end,
		unpack = { "-d", "-c", "-q", "--long=31" },
		heavy = function(o) return o.level > 19 or (tonumber(o.long) or 0) >= 30 end,
	},
	{
		id = "xz",
		key = "x",
		name = "xz (LZMA2)",
		ext = ".xz",
		tars = { ".txz" },
		kind = "stream",
		bin = { "xz" },
		opts = { "level", "extreme", "threads", "extra" },
		over = { level = { min = 0, max = 9, def = 6 } },
		pack = function(o)
			local a = { "-q", "-c", "-" .. o.level, "-T" .. o.threads }
			return o.extreme and add(a, "-e") or a
		end,
		unpack = { "-d", "-c", "-q" },
		heavy = function(o) return o.level >= 9 end,
	},
	{
		id = "lzma",
		key = "l",
		name = "LZMA (alt, .lzma)",
		ext = ".lzma",
		tars = { ".tlz" },
		kind = "stream",
		bin = { "xz" },
		opts = { "level", "extreme", "extra" },
		over = { level = { min = 0, max = 9, def = 6 } },
		pack = function(o)
			local a = { "-q", "-c", "--format=lzma", "-" .. o.level }
			return o.extreme and add(a, "-e") or a
		end,
		unpack = { "-d", "-c", "-q" },
	},
	{
		id = "gz",
		key = "g",
		name = "gzip (Deflate)",
		ext = ".gz",
		tars = { ".tgz" },
		kind = "stream",
		bin = { "pigz", "gzip" },
		opts = { "level", "threads", "extra" },
		over = {
			level = { min = 1, max = 9, def = 6 },
			threads = { hint = "wirkt nur mit pigz (sonst ein Kern)" },
		},
		pack = function(o, ctx)
			local a = { "-q", "-c", "-" .. o.level }
			if ctx.bin == "pigz" and o.threads > 0 then
				add(a, "-p", tostring(o.threads))
			end
			return a
		end,
		unpack = { "-d", "-c", "-q" },
	},
	{
		id = "bz2",
		key = "b",
		name = "bzip2",
		ext = ".bz2",
		tars = { ".tbz2", ".tbz" },
		kind = "stream",
		bin = { "bzip2" },
		opts = { "level", "extra" },
		over = { level = { min = 1, max = 9, def = 9 } },
		pack = function(o) return { "-q", "-c", "-" .. o.level } end,
		unpack = { "-d", "-c", "-q" },
	},
	{
		id = "lz4",
		key = "4",
		name = "LZ4",
		ext = ".lz4",
		tars = {},
		kind = "stream",
		bin = { "lz4" },
		opts = { "level", "extra" },
		over = { level = { min = 1, max = 12, def = 1 } },
		pack = function(o) return { "-q", "-c", "-" .. o.level } end,
		unpack = { "-d", "-c", "-q" },
	},
	{
		id = "br",
		key = "r",
		name = "Brotli",
		ext = ".br",
		tars = {},
		kind = "stream",
		bin = { "brotli" },
		opts = { "level", "extra" },
		over = { level = { min = 0, max = 11, def = 9 } },
		pack = function(o) return { "-c", "-q", tostring(o.level) } end,
		unpack = { "-d", "-c" },
	},
	{
		id = "lz",
		key = "i",
		name = "lzip",
		ext = ".lz",
		tars = {},
		kind = "stream",
		bin = { "lzip" },
		opts = { "level", "extra" },
		over = { level = { min = 0, max = 9, def = 6 } },
		pack = function(o) return { "-q", "-c", "-" .. o.level } end,
		unpack = { "-d", "-c", "-q" },
	},
	{
		id = "tar",
		key = "t",
		name = "tar (unkomprimiert)",
		ext = ".tar",
		tars = {},
		kind = "stream",
		opts = {},
	},
	{
		id = "7z",
		key = "7",
		name = "7-Zip",
		ext = ".7z",
		kind = "7z",
		typ = "7z",
		bin = { "7zz", "7z" },
		password = true,
		opts = { "level", "method", "solid", "threads", "hide", "links", "split", "extra" },
		over = {
			level = { min = 0, max = 9, def = 5, hint = "0 = nur speichern" },
			method = { def = "LZMA2", values = { "LZMA2", "LZMA", "PPMd", "BZip2", "Deflate" } },
			hide = { hint = "wirkt nur mit Passwort" },
		},
		pack = function(o, ctx)
			local a = { "-mx=" .. o.level, "-ms=" .. (o.solid and "on" or "off") }
			add(a, "-mmt=" .. (o.threads > 0 and o.threads or "on"))
			if o.level > 0 then
				add(a, "-m0=" .. o.method)
			end
			if o.hide and ctx.password then
				add(a, "-mhe=on")
			end
			return o.links and add(a, "-snl") or a
		end,
		heavy = function(o) return o.level >= 9 end,
	},
	{
		id = "zip",
		key = "p",
		name = "ZIP",
		ext = ".zip",
		kind = "7z",
		typ = "zip",
		bin = { "7zz", "7z" },
		password = true,
		opts = { "level", "method", "threads", "crypt", "links", "winsafe", "split", "extra" },
		over = {
			level = { min = 0, max = 9, def = 5, hint = "0 = nur speichern" },
			method = {
				def = "Deflate",
				values = { "Deflate", "Deflate64", "BZip2", "LZMA", "PPMd" },
				hint = "nur Deflate ist überall entpackbar",
			},
			crypt = { hint = "wirkt nur mit Passwort; ZipCrypto: unsicher, aber überall lesbar" },
		},
		pack = function(o, ctx)
			-- -mcu=on: Dateinamen immer als UTF-8 kennzeichnen (Umlaute unter Windows/macOS)
			local a = { "-mx=" .. o.level, "-mcu=on", "-mmt=" .. (o.threads > 0 and o.threads or "on") }
			if o.level > 0 then
				add(a, "-mm=" .. o.method)
			end
			if ctx.password then
				add(a, "-mem=" .. o.crypt)
			end
			return o.links and add(a, "-snl") or a
		end,
	},
}

-- Endungen, die beim Entpacken an 7-Zip gehen (alles, was kein Stream-Format ist)
local SEVEN_EXTS = { ".7z", ".zip", ".rar", ".jar", ".apk", ".cbz", ".cbr", ".epub", ".iso", ".cab", ".deb", ".rpm" }
SEVEN_EXTS = add(SEVEN_EXTS, ".xpi", ".whl", ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".arj", ".lzh", ".wim")

-- ── Presets ──
-- Pflicht: key, name, format; id = Name für `--preset=`.  Alle weiteren Felder sind Optionswerte des Formats
-- (siehe OPT) oder die allgemeinen Felder after / verify / tar_files / checksum.
-- Nicht genannte Optionen werden auf den Standard des Formats gesetzt.
local PRESETS = {
	{ key = "1", id = "zstd-3", name = "zstd schnell (-3)", format = "zst", level = 3 },
	{ key = "2", id = "zstd-19", name = "zstd stark (-19)", format = "zst", level = 19 },
	{ key = "3", id = "zstd-22", name = "zstd ultra (-22)", format = "zst", level = 22 },
	{ key = "4", id = "xz-6", name = "xz / LZMA2 (-6)", format = "xz", level = 6 },
	{ key = "5", id = "7z-5", name = "7z LZMA2 (5)", format = "7z", level = 5 },
	{
		-- .zip, das Windows-Explorer, macOS-Archivprogramm und unzip ohne Zusatzsoftware öffnen:
		-- nur Deflate, UTF-8-Namen, keine Symlinks, kein AES, nicht geteilt, Namensprüfung
		key = "b",
		id = "backwordscompability",
		name = "backwordscompability (.zip)",
		format = "zip",
		level = 6,
		method = "Deflate",
		crypt = "ZipCrypto",
		links = false,
		winsafe = true,
	},
}

local AFTER = { "keep", "trash", "delete" }
local AFTER_LABEL = { keep = "Original behalten", trash = "Original → Papierkorb", delete = "Original endgültig löschen" }
local AFTER_LABEL_X = { keep = "Archiv behalten", trash = "Archiv → Papierkorb", delete = "Archiv endgültig löschen" }

local FMT = {} -- id → Format
for _, f in ipairs(FORMATS) do
	FMT[f.id] = f
end

-- Optionsbeschreibung eines Formats (OPT + over)
local function spec(fmt, id)
	local s = {}
	for k, v in pairs(OPT[id]) do
		s[k] = v
	end
	for k, v in pairs((fmt.over or {})[id] or {}) do
		s[k] = v
	end
	return s
end

local function defaults(fmt)
	local o = {}
	for _, id in ipairs(fmt.opts) do
		o[id] = spec(fmt, id).def
	end
	return o
end

-- ════════════════════════════ 2. Hilfsfunktionen ═══════════════════════════

local function notify(level, content, timeout)
	ya.notify { title = "Archiv", content = content, timeout = timeout or 5, level = level }
end

local function fmt_size(n)
	n = n or 0
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local i = 1
	while n >= 1024 and i < #units do
		n = n / 1024
		i = i + 1
	end
	if i == 1 then
		return string.format("%d B", math.floor(n))
	end
	return string.format("%.1f %s", n, units[i])
end

local function basename(p) return p:match("([^/]+)/*$") end

local function dirname(p)
	local d = p:match("^(.*)/[^/]+/*$")
	if d == nil or d == "" then
		return "/"
	end
	return d
end

local function join(dir, name)
	if dir:sub(-1) == "/" then
		return dir .. name
	end
	return dir .. "/" .. name
end

-- "foo.pdf" → "foo", ".pdf" | "README" → "README", "" | ".bashrc" → ".bashrc", ""
local function split_ext(name)
	local stem, ext = name:match("^(.+)(%.[^.]+)$")
	if stem then
		return stem, ext
	end
	return name, ""
end

-- true, wenn `path` gleich `dir` ist oder darin liegt
local function inside(path, dir)
	if dir == "/" then
		return true
	end
	return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

local function tail(lines, n)
	local out = {}
	for i = math.max(1, #lines - n + 1), #lines do
		out[#out + 1] = lines[i]
	end
	return table.concat(out, " | ")
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function words(s)
	local out = {}
	for w in (s or ""):gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

local function rand_id(seed)
	local s = string.format("%s//%.6f//%d", tostring(seed), ya.time(), math.random(1, 1 << 30))
	return ya.hash(s):sub(1, 10)
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("a")
	f:close()
	return s
end

local function read_tail(path, n)
	local f = path and io.open(path, "rb")
	if not f then
		return nil
	end
	local size = f:seek("end") or 0
	f:seek("set", math.max(0, size - n))
	local s = f:read("a") or ""
	f:close()
	return s
end

local function exists(path) return fs.cha(Url(path), false) ~= nil end

-- Archivtyp am Namen erkennen → { fmt, tar, stem } (fmt = nil → 7-Zip)
local SUFFIXES = nil
local function detect(name)
	if not SUFFIXES then
		SUFFIXES = {}
		for _, f in ipairs(FORMATS) do
			if f.kind == "stream" and f.bin then
				add(SUFFIXES, { suf = f.ext, fmt = f, tar = false }, { suf = ".tar" .. f.ext, fmt = f, tar = true })
				for _, t in ipairs(f.tars) do
					add(SUFFIXES, { suf = t, fmt = f, tar = true })
				end
			end
		end
		add(SUFFIXES, { suf = ".tar", fmt = FMT.tar, tar = true })
		for _, e in ipairs(SEVEN_EXTS) do
			add(SUFFIXES, { suf = e })
		end
		table.sort(SUFFIXES, function(a, b) return #a.suf > #b.suf end)
	end
	local low = name:lower()
	if low:match("%.%d%d%d$") then -- geteiltes Archiv: name.7z.001
		local stem = split_ext(name:sub(1, -5))
		return { stem = stem, known = low:match("%.001$") ~= nil }
	end
	for _, s in ipairs(SUFFIXES) do
		if #low > #s.suf and low:sub(-#s.suf) == s.suf then
			return { fmt = s.fmt, tar = s.tar, stem = name:sub(1, #name - #s.suf), known = true }
		end
	end
	return { stem = split_ext(name), known = false }
end

-- ═══════════════════════════ 3. Prozess-Steuerung ══════════════════════════
-- Jeder Prozess läuft als  [setpriv --pdeathsig KILL --] sh -c '<SH>' sh <err> <ein> <aus> prog …
--  • exec → die PID ist direkt das Werkzeug (Abbruch trifft den richtigen Prozess)
--  • stderr landet in einer Datei → keine Pipe, die volllaufen oder Zeilen verlieren kann
--  • Ein-/Ausgabedatei hängt die Shell an stdin/stdout → alle Werkzeuge arbeiten gleich
--  • pdeathsig → endet Yazi, sterben laufende Werkzeuge mit (keine Waisen)

local SH = 'exec 2>"$1" || exit 126; if [ -n "$2" ]; then exec <"$2" || exit 126; fi; '
	.. 'if [ -n "$3" ]; then exec >"$3" || exit 126; fi; shift 3; exec "$@"'

local HAVE_SETPRIV = nil
local ERRDIR = nil

local function have_setpriv()
	if HAVE_SETPRIV == nil then
		local st = Command("setpriv"):arg({ "--pdeathsig", "KILL", "--", "true" }):status()
		HAVE_SETPRIV = st ~= nil and st.success == true
	end
	return HAVE_SETPRIV
end

local function errdir()
	if not ERRDIR then
		local rt_dir = os.getenv("XDG_RUNTIME_DIR")
		ERRDIR = (rt_dir and rt_dir ~= "") and rt_dir or "/tmp"
	end
	return ERRDIR
end

-- ── Aufräum-Register ──
-- Wird Yazi während der Arbeit beendet (oder stürzt ab), bleiben Temp-Dateien
-- liegen. Jede Yazi-Instanz führt daher unter
-- $XDG_STATE_HOME/yazi/zstd-compress/<pid>.list die Pfade ihrer laufenden
-- Temp-Dateien. Beim nächsten Aufruf werden Listen toter Instanzen abgearbeitet.
local INFLIGHT = {}
local OWN_CHECKED = false

local function state_dir()
	local base = os.getenv("XDG_STATE_HOME")
	if not base or base == "" then
		base = (os.getenv("HOME") or "/tmp") .. "/.local/state"
	end
	return base .. "/yazi/zstd-compress"
end

local function my_pid() return (read_file("/proc/self/stat") or ""):match("^(%d+)") or "0" end

local function is_ours(path)
	local b = basename(path) or ""
	return b:match("^%.yazi%-compress%-%x+%.part$") ~= nil or b:match("^yazi%-compress%-%x+%.%a+$") ~= nil
end

-- entfernt eine eigene Temp-Datei / ein eigenes Temp-Verzeichnis samt Teilstücken (.001 …)
local function remove_tmp(path)
	if not is_ours(path) then
		return
	end
	local cha = fs.cha(Url(path), false)
	if cha and cha.is_dir then
		fs.remove("dir_all", Url(path))
	elseif cha then
		fs.remove("file", Url(path))
	end
	for i = 1, 9999 do
		local vol = string.format("%s.%03d", path, i)
		if not exists(vol) then
			break
		end
		fs.remove("file", Url(vol))
	end
end

-- Arbeitet die Liste einer toten Instanz ab. Zuerst werden deren verwaiste
-- Werkzeuge beendet (falls pdeathsig nicht gegriffen hat): Ein Prozess gehört
-- sicher zu uns, wenn sein stderr auf eine unserer .err-Dateien zeigt.
local ORPHANS = 'for f; do for p in /proc/[0-9]*; do '
	.. 'if [ "$(readlink "$p/fd/2" 2>/dev/null)" = "$f" ]; then kill -KILL "${p#/proc/}"; fi; done; done'

local function purge_list(file)
	local paths, errs = {}, {}
	for path in (read_file(file) or ""):gmatch("[^\0]+") do
		paths[#paths + 1] = path
		if is_ours(path) and path:match("%.err$") then
			errs[#errs + 1] = path
		end
	end
	if #errs > 0 then
		Command("sh"):arg({ "-c", ORPHANS, "sh" }):arg(errs):status()
	end
	for _, path in ipairs(paths) do
		remove_tmp(path)
	end
	fs.remove("file", Url(file))
end

local function inflight_save()
	local dir = state_dir()
	local file = join(dir, my_pid() .. ".list")
	if not OWN_CHECKED then
		OWN_CHECKED = true
		purge_list(file) -- gleiche PID wie eine frühere, tote Instanz
	end
	local list = {}
	for path in pairs(INFLIGHT) do
		list[#list + 1] = path
	end
	if #list == 0 then
		fs.remove("file", Url(file))
	else
		fs.create("dir_all", Url(dir))
		fs.write(Url(file), table.concat(list, "\0") .. "\0")
	end
end

local function inflight(path, on)
	INFLIGHT[path] = on or nil
	pcall(inflight_save)
end

local function cleanup_stale()
	local files = fs.read_dir(Url(state_dir()), {})
	local me = my_pid()
	for _, f in ipairs(files or {}) do
		local pid = f.name:match("^(%d+)%.list$")
		if pid and pid ~= me and not (read_file("/proc/" .. pid .. "/comm") or ""):match("^yazi") then
			purge_list(tostring(f.url))
		end
	end
end

local function tmp_path(dir, seed)
	local tmp = join(dir, TMP_PREFIX .. rand_id(seed) .. TMP_SUFFIX)
	inflight(tmp, true)
	return tmp
end

local function drop_tmp(tmp)
	remove_tmp(tmp)
	inflight(tmp, false)
end

-- ── Stufen ──
-- stage = { name, prog, args, input = <Datei für stdin>, output = <Datei für stdout>,
--           feed = <Text für stdin>, cwd, private = <Ausgabe nur für den Besitzer lesbar>,
--           nice = <mit niedrigster CPU-Priorität starten>,
--           warn_code = <Exit-Code, der nur eine Warnung ist>, noisy = <stderr trotz Exit 0 = Warnung> }

local function spawn(s, upstream, piped)
	local errf = join(errdir(), "yazi-compress-" .. rand_id(s.prog) .. ".err")
	inflight(errf, true)
	local a = {}
	if have_setpriv() then
		a = { "--pdeathsig", "KILL", "--", "sh" }
	end
	add(a, "-c", (s.private and "umask 077; " or "") .. SH, "sh", errf, s.input or "", s.output or "")
	if s.nice then
		add(a, "nice", "-n", "19")
	end
	add(a, s.prog)
	for _, x in ipairs(s.args) do
		a[#a + 1] = x
	end
	local c = Command(have_setpriv() and "setpriv" or "sh"):arg(a)
	if s.cwd then
		c = c:cwd(s.cwd)
	end
	c = c:stdin(upstream or (s.feed and Command.PIPED) or Command.NULL)
	c = c:stdout(piped and Command.PIPED or Command.NULL):stderr(Command.NULL)
	local child, err = c:spawn()
	if not child then
		inflight(errf, false)
		return nil, string.format("%s nicht startbar: %s", s.prog, tostring(err))
	end
	if s.feed then
		child:write_all(s.feed)
		child:flush()
	end
	local p = { name = s.name, child = child, errf = errf, err = {}, done = false }
	p.warn_code, p.noisy = s.warn_code, s.noisy
	return p
end

local function collect_err(p)
	if not p.errf then
		return
	end
	local s = read_file(p.errf)
	os.remove(p.errf)
	inflight(p.errf, false)
	p.errf = nil
	for raw in (s or ""):gmatch("[^\r\n]+") do
		local line = raw:gsub("^.*\b", "") -- 7-Zip-Fortschritt wird mit Backspaces überschrieben
		-- Fortschrittszeilen sind keine Meldungen
		local is_progress = line:match("^%s*$") or line:match("^tar: CP %d+$") or line:match("^%s*%d+%%")
		if not is_progress and #p.err < 200 then
			p.err[#p.err + 1] = line
		end
	end
end

-- Wartet, bis alle Prozesse beendet sind; bei Abbruch werden laufende gekillt.
-- Rückgabe: true, wenn abgebrochen wurde.
local function supervise(procs, scope, on_tick)
	local cancelled = false
	local wait = 0.01 -- kurze Prozesse schnell erkennen, dann auf POLL anwachsen
	while true do
		local running = false
		for _, p in ipairs(procs) do
			if not p.done then
				local st, err = p.child:try_wait()
				if st then
					p.done, p.status = true, st
				elseif err then
					p.done, p.wait_err = true, tostring(err)
				else
					running = true
				end
			end
		end
		if not running then
			break
		end
		if scope and scope:cancelled() then
			cancelled = true
			for _, p in ipairs(procs) do
				if not p.done then
					p.child:start_kill()
				end
			end
			for _, p in ipairs(procs) do
				if not p.done then
					p.status = p.child:wait()
					p.done = true
				end
			end
			break
		end
		if on_tick then
			pcall(on_tick, procs)
		end
		ya.sleep(wait)
		wait = math.min(wait * 2, POLL)
	end
	for _, p in ipairs(procs) do
		collect_err(p)
	end
	return cancelled
end

local function kill_all(procs)
	for _, p in ipairs(procs) do
		if not p.done then
			p.child:start_kill()
			p.child:wait()
			p.done = true
		end
		collect_err(p)
	end
end

local function ok(p) return p.status ~= nil and p.status.success == true end

local function describe(p)
	local c
	if p.wait_err then
		c = p.wait_err
	elseif p.status == nil then
		c = "?"
	elseif p.status.code ~= nil then
		c = "Exit " .. p.status.code
	else
		c = "Signal"
	end
	local msg = string.format("%s (%s)", p.name, c)
	if #p.err > 0 then
		msg = msg .. ": " .. tail(p.err, 3)
	end
	return msg
end

-- Startet die Stufen als Pipeline (stdout → stdin) und wartet.
-- Rückgabe: "ok"|"warn"|"fail"|"cancel", Meldung, procs
local function run(stages, scope, on_tick)
	local procs = {}
	for i, s in ipairs(stages) do
		local upstream = i > 1 and procs[i - 1].child:take_stdout() or nil
		local p, err = spawn(s, upstream, stages[i + 1] ~= nil)
		if not p then
			kill_all(procs)
			return "fail", err, procs
		end
		procs[i] = p
	end
	if supervise(procs, scope, on_tick) then
		return "cancel", "abgebrochen", procs
	end
	local bad, warn = {}, {}
	for _, p in ipairs(procs) do
		if ok(p) then
			if p.noisy and #p.err > 0 then
				warn[#warn + 1] = p.name .. ": " .. tail(p.err, 3)
			end
		elseif p.warn_code and p.status and p.status.code == p.warn_code then
			warn[#warn + 1] = describe(p)
		else
			bad[#bad + 1] = describe(p)
		end
	end
	if #bad > 0 then
		return "fail", table.concat(bad, "; "), procs
	elseif #warn > 0 then
		return "warn", table.concat(warn, "; "), procs
	end
	return "ok", nil, procs
end

-- ── Fortschritt ──
-- Liefert eine Tick-Funktion für run(): ermittelt die verarbeiteten Eingabe-Bytes
-- der ersten Stufe und meldet den Zuwachs an `progress`.
--   how = "fd":  Leseposition der Eingabedatei (/proc/<pid>/fdinfo/0)
--   how = "tar": letzte Checkpoint-Meldung von tar (stderr-Datei)
--   how = "7z":  letzte Prozentangabe von 7-Zip (stderr-Datei)
-- `scale` rechnet gelesene Bytes auf `size` um (Test liest das kleinere Archiv).
local function ticker(how, size, progress, scale)
	local reported = 0
	local function report(n)
		n = math.min(math.floor(n * (scale or 1)), size)
		if n > reported then
			progress(n - reported)
			reported = n
		end
	end
	local function tick(procs)
		local p, n = procs[1], nil
		if how == "fd" then
			n = (read_file("/proc/" .. p.child:id() .. "/fdinfo/0") or ""):match("pos:%s*(%d+)")
		elseif how == "tar" then
			for cp in (read_tail(p.errf, 256) or ""):gmatch("CP (%d+)") do
				n = cp * TAR_RECORD
			end
		else
			for pct in (read_tail(p.errf, 512) or ""):gmatch("(%d+)%%") do
				n = pct / 100 * size
			end
		end
		if tonumber(n) then
			report(tonumber(n))
		end
	end
	return tick, function() report(size / (scale or 1)) end
end

-- ══════════════════════════════ 4. Dateisystem ═════════════════════════════

local function mountpoints()
	local mps = {}
	for line in (read_file("/proc/self/mountinfo") or ""):gmatch("[^\n]+") do
		local mp = line:match("^%S+ %S+ %S+ %S+ (%S+)")
		if mp then
			mps[#mps + 1] = (mp:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end))
		end
	end
	return mps
end

-- kleine Hilfsaufrufe (du, chmod, touch …): Ausgabe als Text oder nil
local function tool(prog, args, scope)
	local out = join(errdir(), "yazi-compress-" .. rand_id(prog) .. ".out")
	inflight(out, true)
	local state, msg = run({ { name = prog, prog = prog, args = args, output = out } }, scope)
	local text = read_file(out)
	os.remove(out)
	inflight(out, false)
	if state == "ok" then
		return text or ""
	end
	return nil, msg
end

local function du_bytes(path, scope)
	local n = (tool("du", { "-s", "-b", "--", path }, scope) or ""):match("^(%d+)")
	return n and tonumber(n) or 0
end

-- reserviert atomar einen freien Namen: <stem><suffix>, sonst <stem>_N<suffix>.
-- `volumes` > 0: geteiltes Archiv, <stem><suffix>.001 … müssen alle frei sein.
local function reserve(dir, stem, suffix, volumes)
	volumes = volumes or 0
	for i = 0, 9999 do
		local name = i == 0 and (stem .. suffix) or string.format("%s_%d%s", stem, i, suffix)
		local first = volumes > 0 and (name .. ".001") or name
		local fd, err = fs.access():write(true):create_new(true):open(Url(join(dir, first)))
		if fd then
			local free = true
			for v = 2, volumes do
				free = free and not exists(join(dir, string.format("%s.%03d", name, v)))
			end
			if free then
				return join(dir, name), name
			end
			fs.remove("file", Url(join(dir, first)))
		elseif not err or err.kind ~= "AlreadyExists" then
			return nil, nil, tostring(err)
		end
	end
	return nil, nil, "kein freier Dateiname gefunden"
end

-- verschiebt in den Papierkorb.
-- `path` ist immer absolut ("/…"): gio braucht/verträgt kein "--" (GOption lässt
-- es bei Namen mit führendem "-" als Datei-Argument stehen).
local function trash(path)
	local tried = {}
	for _, t in ipairs { { "gio", { "trash", path } }, { "trash-put", { "--", path } } } do
		local state, msg = run { { name = t[1], prog = t[1], args = t[2] } }
		if state == "ok" then
			return true
		end
		tried[#tried + 1] = msg
	end
	return false, table.concat(tried, "; ")
end

-- Quellen nach erfolgreicher Arbeit behandeln: "keep" | "trash" | "delete"
-- Rückgabe: true/false, Meldung
local function dispose(srcs, after, what)
	if after == "keep" then
		return true, what .. " bleibt"
	end
	local failed = {}
	for _, s in ipairs(srcs) do
		local done, err
		if after == "trash" then
			done, err = trash(s.path)
		else
			done, err = fs.remove(s.kind == "dir" and "dir_all" or "file", Url(s.path))
		end
		if not done then
			failed[#failed + 1] = string.format("%s (%s)", s.name, tostring(err))
		end
	end
	if #failed > 0 then
		local verb = after == "trash" and "nicht in den Papierkorb: " or "nicht gelöscht: "
		return false, verb .. table.concat(failed, ", ")
	end
	return true, what .. (after == "trash" and " im Papierkorb" or " gelöscht")
end

-- ═════════════════════════════════ 5. Jobs ═════════════════════════════════
-- Jeder Job liefert { state = "ok"|"warn"|"fail"|"cancel", msg, url, name, out_size }.

-- Stufen, die ein Archiv vollständig lesen und prüfen
--   arc = { fmt, tar } wie von detect();  typ = 7-Zip-Typ, falls die Endung fehlt
local function check_stages(arc, bins, path, password, typ)
	if not arc.fmt or arc.fmt.kind == "7z" then
		local a = { "t", "-bso0", "-bsp2" }
		if typ then
			add(a, "-t" .. typ)
		end
		add(a, "--", path)
		return { { name = "7z t", prog = bins.seven, args = a, feed = (password or "") .. "\n" } }
	end
	local stages = {}
	if arc.fmt.bin then
		add(stages, { name = arc.fmt.id .. " -d", prog = bins.stream, args = arc.fmt.unpack, input = path })
	end
	if arc.tar then
		add(stages, { name = "tar --list", prog = "tar", args = { "--list", "--file=-" }, input = #stages == 0 and path or nil })
	end
	return stages
end

-- 7-Zip so lange erneut starten, bis das Passwort stimmt oder der Nutzer abbricht
--   attempt(password) → state, msg, procs
local function with_password(name, attempt)
	local password = nil
	while true do
		local state, msg, procs = attempt(password)
		local wants = false
		for _, p in ipairs(procs or {}) do
			wants = wants or (not ok(p) and table.concat(p.err, " "):lower():find("password", 1, true) ~= nil)
		end
		if state ~= "fail" or not wants then
			return state, msg
		end
		local v, event = ya.input {
			title = string.format("Passwort für „%s“:", name),
			obscure = true,
			pos = { "top-center", y = 3, w = 60 },
		}
		if event ~= 1 then
			return "fail", "Passwort erforderlich bzw. falsch"
		end
		password = v
	end
end

-- ── Packen ──
-- job = { kind = "file"|"pack", dir, stem, suffix, size, srcs = { {path, dir, name, kind, mode, len} } }
-- P   = { fmt, o, bins, password, exclude, extra, tar_extra, nice, verify, checksum, after }
local function pack(job, P, scope, progress)
	local fmt, o = P.fmt, P.o
	local tmp = tmp_path(job.dir, job.srcs[1].path)
	local stages, how

	if fmt.kind == "7z" then
		local a = { "a", "-t" .. fmt.typ, "-bso0", "-bsp2", "-y" }
		for _, x in ipairs(fmt.pack(o, { password = P.password ~= nil })) do
			add(a, x)
		end
		if job.wild then
			-- Quelle heißt z. B. "a*.txt": 7-Zip würde das als Muster lesen und auch "ab.txt"
			-- packen. -spd schaltet Muster ab – damit aber auch alle Ausschlüsse.
			add(a, "-spd")
		else
			add(a, "-xr!" .. TMP_GLOB)
			for _, x in ipairs(P.exclude) do
				add(a, "-xr!" .. x)
			end
		end
		if P.password then
			add(a, "-p") -- Passwort kommt über stdin, nie über die Kommandozeile
		end
		if o.split ~= "" then
			add(a, "-v" .. o.split)
		end
		for _, x in ipairs(P.extra) do
			add(a, x)
		end
		add(a, "--", tmp)
		for _, s in ipairs(job.srcs) do
			add(a, s.path)
		end
		local feed = (P.password or "") .. "\n"
		stages = { { name = "7z", prog = P.bins.seven, args = a, feed = feed, warn_code = 1, private = true } }
		how = "7z"
	else
		local zargs = fmt.bin and fmt.pack(o, { size = job.kind == "file" and job.size or nil, bin = P.bins.stream })
		for _, x in ipairs(fmt.bin and P.extra or {}) do
			add(zargs, x)
		end
		if job.kind == "file" then
			local z = { name = fmt.id, prog = P.bins.stream, args = zargs, private = true }
			z.input, z.output = job.srcs[1].path, tmp
			stages, how = { z }, "fd"
		else
			local targs = { "--create", "--file=-", "--exclude=" .. TMP_GLOB }
			add(targs, "--checkpoint=" .. TAR_CP, "--checkpoint-action=echo=CP %u")
			for _, x in ipairs(P.exclude) do
				add(targs, "--exclude=" .. x)
			end
			for _, x in ipairs(P.tar_extra) do
				add(targs, x)
			end
			for _, s in ipairs(job.srcs) do
				add(targs, "--directory=" .. s.dir, "--add-file=" .. s.name)
			end
			-- GNU tar Exit 1 = Datei während des Lesens geändert → Archiv gültig, Original bleibt
			stages = { { name = "tar", prog = "tar", args = targs, warn_code = 1, noisy = true, private = true } }
			if fmt.bin then
				add(stages, { name = fmt.id, prog = P.bins.stream, args = zargs, output = tmp, private = true })
			else
				stages[1].output = tmp
			end
			how = "tar"
		end
	end

	for _, s in ipairs(stages) do
		s.nice = P.nice
	end

	-- mit Integritätstest zählt jeder Job doppelt: erst packen, dann prüfen (job.passes)
	local tick, finish = ticker(how, job.size, progress)
	local vfinish = function() end
	local function failed(state, msg)
		drop_tmp(tmp)
		finish()
		vfinish()
		return { state = state, msg = msg }
	end

	local state, warn = run(stages, scope, tick)
	if state == "fail" or state == "cancel" then
		return failed(state, warn)
	end
	finish()

	-- geteilte Archive: 7-Zip schreibt <tmp>.001, <tmp>.002 …
	local parts = {}
	if fmt.kind == "7z" and o.split ~= "" then
		while exists(string.format("%s.%03d", tmp, #parts + 1)) do
			parts[#parts + 1] = string.format("%s.%03d", tmp, #parts + 1)
		end
		if #parts == 0 then
			return failed("fail", "7-Zip hat keine Teilstücke erzeugt")
		end
	end
	local files = #parts > 0 and parts or { tmp }

	if P.verify then
		local arc = { fmt = fmt, tar = job.kind ~= "file" }
		local packed = fs.cha(Url(files[1]), false)
		local vtick
		if fmt.kind == "7z" then
			vtick, vfinish = ticker("7z", job.size, progress)
		elseif job.size > 0 and packed and packed.len > 0 then
			vtick, vfinish = ticker("fd", job.size, progress, job.size / packed.len)
		end
		local vstages = check_stages(arc, P.bins, files[1], P.password, #parts == 0 and fmt.typ or nil)
		local vstate, vmsg = run(vstages, scope, vtick)
		vfinish()
		if vstate == "cancel" then
			return failed("cancel", "abgebrochen (während Test)")
		elseif vstate ~= "ok" then
			return failed("fail", "Integritätstest fehlgeschlagen: " .. tostring(vmsg))
		end
	end

	-- Rechte nie offener als die Quellen (ohne x-Bits); Einzeldatei behält ihre mtime
	local g = 54 -- 0o066
	for _, s in ipairs(job.srcs) do
		g = g & (s.mode or 0)
	end
	run { { name = "chmod", prog = "chmod", args = add({ string.format("%o", 384 | g), "--" }, table.unpack(files)) } }
	if job.kind == "file" then
		run { { name = "touch", prog = "touch", args = { "-r", job.srcs[1].path, "--", tmp } } }
	end

	if scope:cancelled() then
		return failed("cancel", "abgebrochen (vor dem Umbenennen)")
	end

	local final, final_name, rerr = reserve(job.dir, job.stem, job.suffix, #parts)
	if not final then
		inflight(tmp, false)
		return { state = "fail", msg = string.format("Zielname nicht reservierbar (%s); Archiv liegt als %s", rerr, tmp) }
	end
	local out_size, first = 0, final
	for i, f in ipairs(files) do
		local to = #parts > 0 and string.format("%s.%03d", final, i) or final
		first = i == 1 and to or first
		local renamed, mverr = fs.rename(Url(f), Url(to))
		if not renamed then
			inflight(tmp, false)
			fs.remove("file", Url(first))
			local msg = "Umbenennen fehlgeschlagen (%s); Archiv liegt als %s"
			return { state = "fail", msg = string.format(msg, tostring(mverr), f) }
		end
		local cha = fs.cha(Url(to), false)
		out_size = out_size + (cha and cha.len or 0)
	end
	inflight(tmp, false)
	if #parts > 0 then
		final_name = string.format("%s.001 … .%03d", final_name, #parts)
	end

	local res = { state = "ok", url = first, name = final_name, out_size = out_size }

	if P.checksum then
		local names = {}
		for i = 1, math.max(1, #parts) do
			names[i] = basename(#parts > 0 and string.format("%s.%03d", final, i) or final)
		end
		local sum = { name = "sha256sum", prog = "sha256sum", args = add({ "--" }, table.unpack(names)) }
		sum.cwd, sum.output = job.dir, final .. ".sha256"
		if run({ sum }, scope) ~= "ok" then
			res.state, res.msg = "warn", "SHA-256-Datei nicht erstellt – Original bleibt"
			return res
		end
	end

	if warn then
		res.state, res.msg = "warn", "Original NICHT entfernt – " .. warn
	elseif scope:cancelled() then
		res.state, res.msg = "warn", "Abbruch nach Fertigstellung – Original bleibt"
	else
		local done, msg = dispose(job.srcs, P.after, "Original")
		res.state, res.msg = done and "ok" or "warn", msg
	end
	return res
end

-- ── Entpacken ──
-- job = { dir, size, arc = detect(…), srcs = { archiv } }
-- P   = { bins, subdir = "auto"|"always", after }
local function unpack(job, P, scope, progress)
	local src, arc = job.srcs[1], job.arc
	local tmp = tmp_path(job.dir, src.path)
	local tick, finish = ticker(arc.fmt and "fd" or "7z", job.size, progress)
	local function failed(state, msg)
		drop_tmp(tmp)
		finish()
		return { state = state, msg = msg }
	end

	local state, msg
	if arc.fmt and not arc.tar then
		-- einzelne komprimierte Datei: foo.txt.zst → foo.txt
		local d = { name = arc.fmt.id .. " -d", prog = P.bins.stream, args = arc.fmt.unpack, input = src.path, output = tmp }
		state, msg = run({ d }, scope, tick)
	elseif arc.fmt then
		fs.create("dir", Url(tmp))
		local x = { name = "tar", prog = "tar", args = { "--extract", "--file=-", "--directory=" .. tmp } }
		if arc.fmt.bin then
			local d = { name = arc.fmt.id .. " -d", prog = P.bins.stream, args = arc.fmt.unpack, input = src.path }
			state, msg = run({ d, x }, scope, tick)
		else
			x.input = src.path
			state, msg = run({ x }, scope, tick)
		end
	else
		state, msg = with_password(src.name, function(password)
			remove_tmp(tmp)
			fs.create("dir", Url(tmp))
			local a = { "x", "-bso0", "-bsp2", "-y", "-o" .. tmp, "--", src.path }
			return run({ { name = "7z x", prog = P.bins.seven, args = a, feed = (password or "") .. "\n" } }, scope, tick)
		end)
	end
	if state ~= "ok" then
		return failed(state, msg)
	end
	finish()

	-- Ziel bestimmen
	local target
	if arc.fmt and not arc.tar then
		run { { name = "chmod", prog = "chmod", args = { "--reference=" .. src.path, "--", tmp } } }
		run { { name = "touch", prog = "touch", args = { "-r", src.path, "--", tmp } } }
		local stem, ext = split_ext(arc.stem)
		local final, _, rerr = reserve(job.dir, stem, ext)
		if not final then
			return failed("fail", "Zielname nicht reservierbar: " .. tostring(rerr))
		elseif not fs.rename(Url(tmp), Url(final)) then
			fs.remove("file", Url(final))
			return failed("fail", "Umbenennen fehlgeschlagen")
		end
		target = final
	else
		local outs = fs.read_dir(Url(tmp), { limit = 2 })
		if not outs or #outs == 0 then
			return failed("fail", "Archiv ist leer")
		end
		-- genau ein Eintrag → direkt in den Zielordner, sonst Unterordner mit dem Archivnamen
		local only = #outs == 1 and P.subdir == "auto" and outs[1] or nil
		local kind = (only and not only.cha.is_dir) and "file" or "dir"
		local to = fs.unique(kind, Url(join(job.dir, only and only.name or arc.stem)))
		if not to or not fs.rename(only and only.url or Url(tmp), to) then
			return failed("fail", "Verschieben in den Zielordner fehlgeschlagen")
		end
		target = tostring(to)
		if only then
			fs.remove("dir", Url(tmp))
		end
	end
	inflight(tmp, false)

	local res = { state = "ok", url = target, name = basename(target) }
	if scope:cancelled() then
		res.state, res.msg = "warn", "Abbruch nach Fertigstellung – Archiv bleibt"
	else
		-- geteilte Archive: alle Teilstücke gehören zur Quelle
		local srcs = { src }
		if src.path:match("%.001$") then
			for i = 2, 9999 do
				local vol = string.format("%s.%03d", src.path:sub(1, -5), i)
				if not exists(vol) then
					break
				end
				srcs[#srcs + 1] = { path = vol, name = basename(vol), kind = "file" }
			end
		end
		local done, dmsg = dispose(srcs, P.after, "Archiv")
		res.state, res.msg = done and "ok" or "warn", dmsg
	end
	return res
end

-- ── Testen ──
local function test(job, P, scope, progress)
	local src, arc = job.srcs[1], job.arc
	local tick, finish = ticker(arc.fmt and "fd" or "7z", job.size, progress)
	local state, msg
	if arc.fmt then
		state, msg = run(check_stages(arc, P.bins, src.path), scope, tick)
	else
		state, msg = with_password(
			src.name,
			function(password) return run(check_stages(arc, P.bins, src.path, password), scope, tick) end
		)
	end
	finish()
	if state ~= "ok" then
		return { state = state, msg = msg }
	end
	return { state = "ok", name = src.name, url = src.path, msg = "Archiv ist in Ordnung" }
end

-- ══════════════════ 6. Gespeicherte Einstellungen + Presets ════════════════
-- $XDG_STATE_HOME/yazi/zstd-compress/settings.ini — zuletzt benutzte Werte und
-- eigene Presets. Passwörter werden nie gespeichert.

-- S = { format, after, verify, tar_files, checksum, exclude, tar_extra, stamp, nice,
--       x_subdir, x_after, o = { <fmt> = { Optionswerte } }, user = { eigene Presets } }
local S = nil

local GLOBALS = { -- allgemeine Felder: Name → Typ
	after = "after",
	verify = "bool",
	tar_files = "bool",
	checksum = "bool",
	exclude = "text",
	tar_extra = "text",
	stamp = "bool",
	nice = "bool",
	x_subdir = "subdir",
	x_after = "after",
}

local function coerce(kind, v, sp)
	if kind == "bool" then
		return v == "1" or v == "true"
	elseif kind == "int" then
		local n = math.tointeger(tonumber(v))
		return (n and n >= sp.min and n <= sp.max) and n or sp.def
	elseif kind == "choice" then
		for _, x in ipairs(sp.values) do
			if x == v then
				return v
			end
		end
		return sp.def
	elseif kind == "after" then
		return (v == "trash" or v == "delete") and v or "keep"
	elseif kind == "subdir" then
		return v == "always" and v or "auto"
	end
	return v
end

local function settings_file() return join(state_dir(), "settings.ini") end

local function fresh_state()
	local s = { format = "zst", after = "keep", verify = true, tar_files = false, checksum = false, exclude = "" }
	s.tar_extra, s.stamp, s.nice = "", false, false
	s.x_subdir, s.x_after, s.o, s.user = "auto", "keep", {}, {}
	for _, f in ipairs(FORMATS) do
		s.o[f.id] = defaults(f)
	end
	return s
end

-- Preset-Felder (Strings oder Lua-Werte) auf das Format prüfen und übernehmen
local function preset_values(fmt, src, from_text)
	local o = defaults(fmt)
	for _, id in ipairs(fmt.opts) do
		local v = src[id]
		if v ~= nil then
			local sp = spec(fmt, id)
			if not from_text and sp.type == "bool" then
				o[id] = v == true
			else
				o[id] = coerce(sp.type, tostring(v), sp)
			end
		end
	end
	return o
end

local function load_state()
	local s = fresh_state()
	local cur = nil -- aktuelles [preset]
	for line in (read_file(settings_file()) or ""):gmatch("[^\n]+") do
		local k, v = line:match("^([%w_.]+)=(.*)$")
		if line == "[preset]" then
			cur = {}
			s.user[#s.user + 1] = cur
		elseif k and cur then
			cur[k] = v
		elseif k == "format" then
			s.format = FMT[v] and v or s.format
		elseif k and GLOBALS[k] then
			s[k] = coerce(GLOBALS[k], v)
		elseif k then
			local f, id = k:match("^o%.(%w+)%.(%w+)$")
			if f and FMT[f] and s.o[f][id] ~= nil then
				local sp = spec(FMT[f], id)
				s.o[f][id] = coerce(sp.type, v, sp)
			end
		end
	end
	-- eigene Presets: nur gültige behalten
	local user = {}
	for _, p in ipairs(s.user) do
		if p.name and p.key and FMT[p.format or ""] then
			local u = { name = p.name, key = p.key, format = p.format, user = true }
			u.o = preset_values(FMT[p.format], p, true)
			for k, kind in pairs(GLOBALS) do
				if p[k] ~= nil then
					u[k] = coerce(kind, p[k])
				end
			end
			user[#user + 1] = u
		end
	end
	s.user = user
	return s
end

local function text_of(v)
	if type(v) == "boolean" then
		return v and "1" or "0"
	end
	return (tostring(v):gsub("[\r\n]", " "))
end

local function save_state()
	local out = { "# zstd-compress.yazi – wird vom Plugin geschrieben", "format=" .. S.format }
	for k in pairs(GLOBALS) do
		out[#out + 1] = k .. "=" .. text_of(S[k])
	end
	for _, f in ipairs(FORMATS) do
		for _, id in ipairs(f.opts) do
			out[#out + 1] = string.format("o.%s.%s=%s", f.id, id, text_of(S.o[f.id][id]))
		end
	end
	for _, p in ipairs(S.user) do
		add(out, "[preset]", "name=" .. text_of(p.name), "key=" .. p.key, "format=" .. p.format)
		for _, id in ipairs(FMT[p.format].opts) do
			out[#out + 1] = id .. "=" .. text_of(p.o[id])
		end
		for k in pairs(GLOBALS) do
			if p[k] ~= nil then
				out[#out + 1] = k .. "=" .. text_of(p[k])
			end
		end
	end
	fs.create("dir_all", Url(state_dir()))
	fs.write(Url(settings_file()), table.concat(out, "\n") .. "\n")
end

-- alle Presets: eingebaute (PRESETS) + eigene; gleiche Taste → das eigene gewinnt
local function presets()
	local list, by_key = {}, {}
	for _, p in ipairs(PRESETS) do
		if FMT[p.format] then
			local q = { name = p.name, key = p.key, id = p.id, format = p.format, o = preset_values(FMT[p.format], p, false) }
			for k in pairs(GLOBALS) do
				q[k] = p[k]
			end
			by_key[q.key] = q
			list[#list + 1] = q
		end
	end
	for _, p in ipairs(S.user) do
		if by_key[p.key] then
			for i, q in ipairs(list) do
				if q.key == p.key then
					list[i] = p
				end
			end
		else
			list[#list + 1] = p
		end
		by_key[p.key] = p
	end
	return list
end

local function apply_preset(p)
	S.format = p.format
	S.o[p.format] = {}
	for k, v in pairs(p.o) do
		S.o[p.format][k] = v
	end
	for k in pairs(GLOBALS) do
		if p[k] ~= nil then
			S[k] = p[k]
		end
	end
end

-- ══════════════════════════════ 7. Oberfläche ══════════════════════════════

local AVAIL = {} -- vorhandene Werkzeuge

local function probe_tools()
	local names, seen = { "tar", "gio", "trash-put", "sha256sum", "find" }, {}
	for _, f in ipairs(FORMATS) do
		for _, b in ipairs(f.bin or {}) do
			if not seen[b] then
				seen[b] = true
				names[#names + 1] = b
			end
		end
	end
	local script = 'for b; do command -v "$b" >/dev/null 2>&1 && printf "%s\\n" "$b"; done'
	local out = Command("sh"):arg({ "-c", script, "sh" }):arg(names):stdout(Command.PIPED):output()
	AVAIL = {}
	for b in ((out and out.stdout) or ""):gmatch("[^\n]+") do
		AVAIL[b] = true
	end
end

-- erstes vorhandenes Werkzeug eines Formats (reines tar: "tar")
local function pick(fmt)
	if not fmt.bin then
		return AVAIL.tar and "tar" or nil
	end
	for _, b in ipairs(fmt.bin) do
		if AVAIL[b] then
			return b
		end
	end
	return nil
end

local function ask_text(title, value, obscure)
	local v, event = ya.input {
		title = title,
		value = value or "",
		obscure = obscure or false,
		pos = { "top-center", y = 3, w = 70 },
	}
	if event ~= 1 then
		return nil
	end
	return v or ""
end

local function show(sp, v)
	if sp.type == "bool" then
		return v and "an" or "aus"
	elseif sp.type == "int" and v == 0 and sp.zero then
		return sp.zero
	elseif sp.type == "text" then
		return v == "" and "–" or v
	end
	return tostring(v)
end

-- Auswahlmenü: items = { {key, text} … } → Index oder nil
local function menu(items)
	local cands = {}
	for i, it in ipairs(items) do
		cands[i] = { on = it[1], desc = it[2] }
	end
	return ya.which { cands = cands, silent = false }
end

local DIGITS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }

-- Wert einer Option bearbeiten → neuer Wert
local function edit(sp, v)
	if sp.type == "bool" then
		return not v
	elseif sp.type == "choice" then
		local items = {}
		for i, x in ipairs(sp.values) do
			items[i] = { DIGITS[i], x .. (x == v and "  ✓" or "") }
		end
		local i = menu(items)
		return i and sp.values[i] or v
	elseif sp.type == "int" then
		local range = string.format("%d … %d", sp.min, sp.max)
		while true do
			local s = ask_text(string.format("%s (%s):", sp.label, sp.hint or range), tostring(v))
			if s == nil then
				return v
			end
			local n = math.tointeger(tonumber(trim(s)))
			if n and n >= sp.min and n <= sp.max then
				return n
			end
			notify("warn", string.format("%s: ganze Zahl %s erwartet", sp.label, range))
		end
	end
	local s = ask_text(string.format("%s%s:", sp.label, sp.hint and (" (" .. sp.hint .. ")") or ""), v)
	return s == nil and v or trim(s)
end

-- Kurzbeschreibung der aktuellen Einstellungen, z. B. "zst -19 · Original behalten"
local function summary()
	local fmt, o = FMT[S.format], S.o[S.format]
	local s = fmt.id
	if o.level and fmt.kind == "7z" then
		s = s .. " Stufe " .. o.level
	elseif o.level then
		s = s .. (o.level < 0 and (" --fast=" .. -o.level) or (" -" .. o.level))
	end
	if o.method then
		s = s .. " " .. o.method
	end
	return s
end

local function ask_password()
	local a = ask_text("Passwort (leer = ohne Passwort):", "", true)
	if a == nil then
		return false
	elseif a == "" then
		return nil
	end
	local b = ask_text("Passwort wiederholen:", "", true)
	if b ~= a then
		notify("warn", "Passwörter stimmen nicht überein – nichts geändert.")
		return false
	end
	return a
end

-- Zielordner abfragen → absoluter Pfad, "" (zurücksetzen) oder nil (unverändert)
local function ask_dir(current, fallback)
	local v = ask_text("Zielordner (leer = Standard):", current or fallback or "")
	if v == nil then
		return nil
	end
	v = trim(v)
	if v == "" then
		return ""
	end
	local home = os.getenv("HOME") or ""
	v = v:gsub("^~", home)
	if #v > 1 then
		v = v:gsub("/+$", "")
	end
	local cha = fs.cha(Url(v), true)
	if v:sub(1, 1) ~= "/" or not cha or not cha.is_dir then
		notify("warn", "Kein vorhandener Ordner (absoluter Pfad nötig): " .. v)
		return nil
	end
	return v
end

local function manage_presets()
	local i = menu {
		{ "s", "aktuelle Einstellungen als Preset speichern" },
		{ "d", "eigenes Preset löschen" },
	}
	if i == 1 then
		local used, key = {}, nil
		for _, p in ipairs(presets()) do
			used[p.key] = true
		end
		for _, d in ipairs(DIGITS) do
			key = key or (not used[d] and d or nil)
		end
		if not key then
			notify("warn", "Alle Zifferntasten sind belegt – erst ein eigenes Preset löschen.")
			return
		end
		local name = ask_text(string.format("Name des Presets (Taste %s):", key), summary())
		name = name and trim(name) or ""
		if name == "" then
			return
		end
		local p = { name = name, key = key, format = S.format, user = true, o = {} }
		for k, v in pairs(S.o[S.format]) do
			p.o[k] = v
		end
		for k in pairs(GLOBALS) do
			if k:sub(1, 2) ~= "x_" then
				p[k] = S[k]
			end
		end
		S.user[#S.user + 1] = p
		save_state()
		notify("info", string.format("Preset „%s“ auf Taste %s gespeichert.", name, key))
	elseif i == 2 then
		if #S.user == 0 then
			notify("info", "Keine eigenen Presets vorhanden.")
			return
		end
		local items = {}
		for n, p in ipairs(S.user) do
			items[n] = { p.key, p.name }
		end
		local n = menu(items)
		if n then
			table.remove(S.user, n)
			save_state()
		end
	end
end

local function choose_format()
	local items, ids = {}, {}
	for _, f in ipairs(FORMATS) do
		if pick(f) then
			local ext = f.kind == "stream" and f.bin and (f.ext .. " / .tar" .. f.ext) or f.ext
			items[#items + 1] = { f.key, string.format("%s  (%s)", f.name, ext) }
			ids[#ids + 1] = f.id
		end
	end
	local i = menu(items)
	if i then
		S.format = ids[i]
	end
end

-- Formular „Komprimieren“. T = Angaben nur für diesen Aufruf { mode, dest, password }
-- Rückgabe: "start" | "extract" | nil
local function pack_form(st, T)
	local MODE = { m = "je Eintrag ein Archiv", s = "ein gemeinsames Archiv" }
	while true do
		local fmt = FMT[S.format]
		if not pick(fmt) then -- Werkzeug des gemerkten Formats fehlt
			for _, f in ipairs(FORMATS) do
				if pick(f) then
					fmt, S.format = f, f.id
					break
				end
			end
		end
		local o = S.o[fmt.id]
		local rows = {}
		local function row(key, text, act) rows[#rows + 1] = { key, text, act = act } end

		row("<Enter>", string.format("▶ START  %s · %s", summary(), AFTER_LABEL[S.after]), "start")
		for _, p in ipairs(presets()) do
			if pick(FMT[p.format]) then
				row(p.key, "▶ Preset: " .. p.name, function()
					apply_preset(p)
					return "start"
				end)
			end
		end
		row("f", "Format: " .. fmt.name, choose_format)
		for _, id in ipairs(fmt.opts) do
			local sp = spec(fmt, id)
			row(sp.key, sp.label .. ": " .. show(sp, o[id]), function() o[id] = edit(sp, o[id]) end)
		end
		if fmt.password then
			row("k", "Passwort: " .. (T.password and "gesetzt" or "–"), function()
				local p = ask_password()
				if p ~= false then
					T.password = p
				end
			end)
		end
		row("a", "Danach: " .. AFTER_LABEL[S.after], function()
			local i = menu { { "b", AFTER_LABEL.keep }, { "p", AFTER_LABEL.trash }, { "l", AFTER_LABEL.delete } }
			S.after = i and AFTER[i] or S.after
		end)
		if #st.paths > 1 then
			row("m", "Mehrere: " .. (MODE[T.mode] or "beim Start fragen"), function()
				local i = menu { { "m", MODE.m }, { "s", MODE.s }, { "f", "beim Start fragen" } }
				if i then
					T.mode = ({ "m", "s" })[i] -- 3 → nil = beim Start fragen
				end
			end)
		end
		row("o", "Zielordner: " .. (T.dest or "neben der Quelle"), function()
			local d = ask_dir(T.dest, st.cwd)
			if d then
				T.dest = d ~= "" and d or nil
			end
		end)
		row("E", "Ausschließen: " .. (S.exclude == "" and "–" or S.exclude), function()
			local v = ask_text("Muster ausschließen (durch Leerzeichen getrennt, z. B. .git *.o):", S.exclude)
			S.exclude = v and trim(v) or S.exclude
		end)
		if fmt.kind == "stream" then
			row("T", "tar-Argumente: " .. (S.tar_extra == "" and "–" or S.tar_extra), function()
				local v = ask_text("Zusatz-Argumente für tar (z. B. --xattrs --acls --one-file-system):", S.tar_extra)
				S.tar_extra = v and trim(v) or S.tar_extra
			end)
		end
		if fmt.kind == "stream" and fmt.bin then
			row("i", "Einzeldatei in tar packen: " .. (S.tar_files and "an" or "aus"), function() S.tar_files = not S.tar_files end)
		end
		row("D", "Datum an den Namen: " .. (S.stamp and "an" or "aus"), function() S.stamp = not S.stamp end)
		row("N", "Schonend (nice 19): " .. (S.nice and "an" or "aus"), function() S.nice = not S.nice end)
		row("v", "Integritätstest: " .. (S.verify and "an" or "aus"), function() S.verify = not S.verify end)
		row("C", "SHA-256-Datei: " .. (S.checksum and "an" or "aus"), function() S.checksum = not S.checksum end)
		row("P", "Presets verwalten …", manage_presets)
		if st.archives then
			row("X", "Stattdessen entpacken …", "extract")
		end

		local i = menu(rows)
		if not i then
			return nil
		end
		local act = rows[i].act
		local r = type(act) == "function" and act() or act
		if r == "start" or r == "extract" then
			return r
		end
	end
end

-- Formular „Entpacken“. Rückgabe: "extract" | "test" | nil
local function unpack_form(st, T)
	local SUB = { auto = "nur wenn nötig", always = "immer" }
	while true do
		local rows = {}
		local function row(key, text, act) rows[#rows + 1] = { key, text, act = act } end
		local n = #st.paths == 1 and basename(st.paths[1]) or (#st.paths .. " Archive")
		row("<Enter>", "▶ ENTPACKEN  " .. n, "extract")
		row("t", "▶ nur testen (Integrität)", "test")
		row("u", "Unterordner anlegen: " .. SUB[S.x_subdir], function()
			S.x_subdir = S.x_subdir == "auto" and "always" or "auto"
		end)
		row("o", "Zielordner: " .. (T.dest or "neben dem Archiv"), function()
			local d = ask_dir(T.dest, st.cwd)
			if d then
				T.dest = d ~= "" and d or nil
			end
		end)
		row("a", "Danach: " .. AFTER_LABEL_X[S.x_after], function()
			local i = menu { { "b", AFTER_LABEL_X.keep }, { "p", AFTER_LABEL_X.trash }, { "l", AFTER_LABEL_X.delete } }
			S.x_after = i and AFTER[i] or S.x_after
		end)
		local i = menu(rows)
		if not i then
			return nil
		end
		local act = rows[i].act
		if type(act) == "function" then
			act()
		else
			return act
		end
	end
end

-- ── Vorbereitung ──

local function stat_items(paths)
	local items, skipped = {}, {}
	for _, path in ipairs(paths) do
		local name = basename(path)
		local cha, err = fs.cha(Url(path), false)
		if path:sub(1, 1) ~= "/" then
			skipped[#skipped + 1] = path .. ": kein absoluter Pfad"
		elseif not name or path == "/" then
			skipped[#skipped + 1] = path .. ": Wurzelverzeichnis"
		elseif not cha then
			skipped[#skipped + 1] = name .. ": " .. tostring(err)
		else
			local kind
			if cha.is_link then
				kind = "link"
			elseif cha.is_dir then
				kind = "dir"
			elseif cha.is_fifo or cha.is_sock or cha.is_char or cha.is_block then
				kind = "special"
			else
				kind = "file"
			end
			items[#items + 1] = {
				path = path,
				dir = dirname(path),
				name = name,
				kind = kind,
				mode = (cha.mode or 0) & 511,
				len = cha.len or 0,
			}
		end
	end
	return items, skipped
end

local function ask_name(default, suffix)
	local value = default
	while true do
		local v = ask_text(string.format("Archivname (%s wird ergänzt):", suffix), value)
		if v == nil then
			return nil
		end
		v = trim(v)
		if v:sub(-#suffix) == suffix then
			v = v:sub(1, #v - #suffix)
		end
		if v == "" or v == "." or v == ".." or v:find("/", 1, true) or v:find("\0", 1, true) then
			notify("warn", "Ungültiger Name: " .. (v == "" and "(leer)" or v))
			value = default
		elseif #v > 200 then
			notify("warn", "Name zu lang (max. 200 Byte)")
			value = v:sub(1, 200)
		else
			return v
		end
	end
end

-- Namen, die unter Windows nicht anlegbar sind (Zeichen, Endung, reservierte Namen)
local function windows_unsafe(items)
	local a = { "-H" }
	for _, it in ipairs(items) do
		add(a, it.path)
	end
	add(a, "(", "-name", '*[<>:"|?*\\\\]*', "-o", "-name", "* ", "-o", "-name", "*.")
	for _, r in ipairs { "con", "prn", "aux", "nul", "com[1-9]", "lpt[1-9]" } do
		add(a, "-o", "-iname", r, "-o", "-iname", r .. ".*")
	end
	add(a, ")", "-print")
	local out = tool("find", a) or ""
	local list = {}
	for line in out:gmatch("[^\n]+") do
		list[#list + 1] = line
	end
	return list
end

local function confirm(title, body)
	return ya.confirm { pos = { "center", w = 70, h = 14 }, title = title, body = body }
end

-- Einstellungen → Parameter für pack(); nil + Meldung, wenn etwas fehlt
local function pack_params(T)
	local fmt = FMT[S.format]
	local P = { fmt = fmt, o = S.o[fmt.id], after = S.after, checksum = S.checksum and AVAIL.sha256sum }
	P.bins = { stream = fmt.kind == "stream" and pick(fmt) or nil, seven = pick(FMT["7z"]) }
	P.password = fmt.password and T.password or nil
	P.exclude = words(S.exclude)
	P.tar_extra, P.nice = words(S.tar_extra), S.nice
	P.extra = words(P.o.extra)
	P.verify = S.verify or S.after ~= "keep" -- nie ungeprüft löschen
	P.heavy = fmt.heavy ~= nil and fmt.heavy(P.o) == true
	if not pick(fmt) then
		return nil, string.format("Werkzeug für %s fehlt (%s).", fmt.name, table.concat(fmt.bin or { "tar" }, " / "))
	elseif not AVAIL.tar and fmt.kind == "stream" then
		return nil, "tar fehlt."
	end
	return P
end

-- Abfragen; liefert jobs, skipped, P, title oder nil (abgebrochen/nichts zu tun)
local function prepare_pack(st, T)
	local P, perr = pack_params(T)
	if not P then
		notify("error", perr)
		return nil
	end
	local fmt = P.fmt

	local mode = "m"
	if #st.paths > 1 then
		mode = T.mode
		if not mode then
			local mi = menu {
				{ "s", string.format("ein Archiv für alle %d Einträge (single)", #st.paths) },
				{ "m", string.format("%d einzelne Archive (multiple)", #st.paths) },
				{ "c", "abbrechen (cancel)" },
			}
			mode = ({ "s", "m" })[mi or 3]
			if not mode then
				return nil
			end
		end
	end

	local items, skipped = stat_items(st.paths)
	if st.virtual > 0 then
		skipped[#skipped + 1] = st.virtual .. " Einträge auf VFS/SFTP (nicht unterstützt)"
	end

	local stamp = S.stamp and os.date("_%Y-%m-%d_%H%M") or ""
	-- Container-Endung: .tar.zst / .tar / .7z / .zip
	local box = fmt.kind == "7z" and fmt.ext or (fmt.bin and (".tar" .. fmt.ext) or ".tar")
	local jobs = {}
	if mode == "s" then
		local dir = T.dest or st.cwd
		if #skipped > 0 then
			notify("error", "Abbruch – " .. table.concat(skipped, "; "), 8)
			return nil
		elseif not dir then
			notify("error", "Abbruch – aktueller Ordner ist kein lokales Verzeichnis.")
			return nil
		end
		local seen = {}
		for _, it in ipairs(items) do
			if seen[it.name] then
				notify("error", "Abbruch – Name doppelt im Archiv: " .. it.name, 8)
				return nil
			elseif it.kind == "dir" and inside(dir, it.path) then
				notify("error", "Abbruch – das Archiv läge in „" .. it.name .. "“, das selbst gepackt wird.", 8)
				return nil
			end
			seen[it.name] = true
		end
		local name = ask_name((basename(st.cwd or dir) or "archiv") .. stamp, box)
		if not name then
			return nil
		end
		jobs[1] = { kind = "pack", dir = dir, stem = name, suffix = box, srcs = items }
	else
		for _, it in ipairs(items) do
			local dir = T.dest or it.dir
			if it.kind == "link" then
				skipped[#skipped + 1] = it.name .. ": symbolischer Link"
			elseif it.kind == "special" then
				skipped[#skipped + 1] = it.name .. ": Sonderdatei (FIFO/Socket/Gerät)"
			elseif it.kind == "dir" and inside(dir, it.path) then
				skipped[#skipped + 1] = it.name .. ": Zielordner liegt in diesem Ordner"
			elseif it.kind == "dir" then
				jobs[#jobs + 1] = { kind = "pack", dir = dir, stem = it.name .. stamp, suffix = box, srcs = { it } }
			elseif fmt.kind == "stream" and fmt.bin and not S.tar_files then
				local stem, ext = split_ext(it.name)
				jobs[#jobs + 1] = { kind = "file", dir = dir, stem = stem .. stamp, suffix = ext .. fmt.ext, srcs = { it } }
			else
				jobs[#jobs + 1] = { kind = "pack", dir = dir, stem = split_ext(it.name) .. stamp, suffix = box, srcs = { it } }
			end
		end
	end

	if #jobs == 0 then
		notify("warn", "Nichts zu tun – " .. table.concat(skipped, "; "), 8)
		return nil
	end

	if P.o.winsafe then
		local bad = windows_unsafe(items)
		if #bad > 0 then
			local sample = table.concat(bad, "\n", 1, math.min(#bad, 5))
			local body = string.format("%d Namen sind unter Windows ungültig, z. B.:\n\n%s\n\nTrotzdem packen?", #bad, sample)
			if not confirm("Windows-Namen", body) then
				return nil
			end
		end
	end
	if P.after == "delete" then
		local body = "Nach erfolgreichem Packen und Prüfen werden\ndie Originale ENDGÜLTIG gelöscht (kein Papierkorb).\n\nFortfahren?"
		if not confirm("Originale endgültig löschen?", body) then
			return nil
		end
	end

	for _, job in ipairs(jobs) do
		for _, s in ipairs(job.srcs) do
			job.wild = job.wild or s.name:find("[*?]") ~= nil
		end
		if job.wild and fmt.kind == "7z" and #P.exclude > 0 then
			notify("error", "Abbruch – „Ausschließen“ geht bei 7z/zip nicht, wenn ein gewählter Name * oder ? enthält.", 8)
			return nil
		end
		job.label = job.stem .. job.suffix
		job.run = function(scope, progress) return pack(job, P, scope, progress) end
		job.heavy, job.guard_mounts, job.passes = P.heavy, true, P.verify and 2 or 1
	end
	local title = #jobs == 1 and string.format("%s: %s", summary(), jobs[1].label)
		or string.format("%s: %d Archive", summary(), #jobs)
	return jobs, skipped, title
end

local function prepare_unpack(st, T, action)
	local items, skipped = stat_items(st.paths)
	if st.virtual > 0 then
		skipped[#skipped + 1] = st.virtual .. " Einträge auf VFS/SFTP (nicht unterstützt)"
	end
	local seven = pick(FMT["7z"])
	local jobs = {}
	for _, it in ipairs(items) do
		local arc = detect(it.name)
		local bins = { seven = seven, stream = arc.fmt and pick(arc.fmt) or nil }
		local low = it.name:lower()
		if it.kind ~= "file" then
			skipped[#skipped + 1] = it.name .. ": keine Datei"
		elseif low:match("%.%d%d%d$") and not low:match("%.001$") then
			-- Teilstück eines geteilten Archivs: nur .001 wird verarbeitet
			if not st.from_selection then
				skipped[#skipped + 1] = it.name .. ": bitte das erste Teilstück (.001) wählen"
			end
		elseif arc.fmt and not bins.stream then
			skipped[#skipped + 1] = string.format("%s: Werkzeug fehlt (%s)", it.name, table.concat(arc.fmt.bin or { "tar" }, "/"))
		elseif not arc.fmt and not seven then
			skipped[#skipped + 1] = it.name .. ": 7-Zip fehlt (7zz / 7z)"
		else
			local P = { bins = bins, subdir = S.x_subdir, after = S.x_after }
			local job = { dir = T.dest or it.dir, arc = arc, srcs = { it }, label = it.name }
			local fn = action == "test" and test or unpack
			job.run = function(scope, progress) return fn(job, P, scope, progress) end
			jobs[#jobs + 1] = job
		end
	end
	if #jobs == 0 then
		notify("warn", "Nichts zu tun – " .. table.concat(skipped, "; "), 8)
		return nil
	end
	if action ~= "test" and S.x_after == "delete" then
		if not confirm("Archive endgültig löschen?", "Nach erfolgreichem Entpacken werden\ndie Archive ENDGÜLTIG gelöscht (kein Papierkorb).\n\nFortfahren?") then
			return nil
		end
	end
	local verb = action == "test" and "Testen" or "Entpacken"
	local title = #jobs == 1 and (verb .. ": " .. jobs[1].label) or string.format("%s: %d Archive", verb, #jobs)
	return jobs, skipped, title
end

-- ══════════════════════════ 8. Ausführung, Einstieg ════════════════════════

local function slot_acquire(slots, heavy, scope, task)
	local logged = false
	while slots.all >= CFG.max_parallel or (heavy and slots.heavy >= CFG.max_heavy) do
		if scope:cancelled() then
			return false
		end
		if not logged then
			task:log("Warte auf freien Slot …")
			logged = true
		end
		ya.sleep(0.5)
	end
	slots.all = slots.all + 1
	if heavy then
		slots.heavy = slots.heavy + 1
	end
	return true
end

local function slot_release(slots, heavy)
	slots.all = math.max(0, slots.all - 1)
	if heavy then
		slots.heavy = math.max(0, slots.heavy - 1)
	end
end

local function execute(self, task, scope, jobs, skipped, title)
	task:progress { total = #jobs }
	for _, s in ipairs(skipped) do
		task:log("ÜBERSPRUNGEN " .. s)
	end

	-- Größen (für die %-Anzeige) + Schutz vor Ordnern mit Mountpunkten darin
	local mps = mountpoints()
	local workload = 0
	for _, job in ipairs(jobs) do
		job.size = 0
		for _, s in ipairs(job.srcs) do
			if scope:cancelled() then
				break
			end
			if s.kind == "dir" then
				for _, mp in ipairs(job.guard_mounts and mps or {}) do
					if mp ~= s.path and inside(mp, s.path) then
						job.blocked = "enthält Mountpunkt " .. mp .. " (übersprungen)"
						break
					end
				end
				if not job.blocked then
					job.size = job.size + du_bytes(s.path, scope)
				end
			else
				job.size = job.size + s.len
			end
		end
		workload = workload + job.size * (job.passes or 1)
	end
	if workload > 0 then
		task:progress { workload = workload }
	end

	local n = { ok = 0, warn = 0, fail = 0, cancel = 0 }
	local urls, lines = {}, {}
	for _, job in ipairs(jobs) do
		local res
		if scope:cancelled() then
			res = { state = "cancel", msg = "abgebrochen" }
		elseif job.blocked then
			res = { state = "fail", msg = job.blocked }
		elseif not slot_acquire(self.slots, job.heavy, scope, task) then
			res = { state = "cancel", msg = "abgebrochen (Warteschlange)" }
		else
			local okc, r = pcall(job.run, scope, function(d) task:progress { processed = d } end)
			slot_release(self.slots, job.heavy)
			res = okc and r or { state = "fail", msg = "interner Fehler: " .. tostring(r) }
		end

		local line
		if res.state == "ok" or res.state == "warn" then
			urls[#urls + 1] = Url(res.url)
			local sizes = ""
			if res.out_size then
				local ratio = job.size > 0 and string.format(" (%.1f %%)", res.out_size / job.size * 100) or ""
				sizes = string.format(" · %s → %s%s", fmt_size(job.size), fmt_size(res.out_size), ratio)
			end
			line = string.format("%s %s%s · %s", res.state == "ok" and "OK" or "WARNUNG", res.name, sizes, res.msg)
			task:progress(res.state == "ok" and { success = 1 } or { failed = 1 })
		else
			local tag = res.state == "cancel" and "ABGEBROCHEN" or "FEHLER"
			line = string.format("%s %s · %s", tag, job.label, tostring(res.msg))
			task:progress { failed = 1 }
		end
		n[res.state] = n[res.state] + 1
		task:log(line)
		lines[#lines + 1] = line
	end

	if n.cancel > 0 and n.ok + n.warn == 0 then
		task:fail("Abgebrochen – keine Änderungen")
		notify("warn", "Abgebrochen – Temp-Dateien entfernt, Originale unverändert.")
		return
	end

	local parts = {}
	for _, x in ipairs {
		{ n.ok, "OK" },
		{ n.warn, "Warnung" },
		{ n.fail, "Fehler" },
		{ n.cancel, "abgebrochen" },
		{ #skipped, "übersprungen" },
	} do
		if x[1] > 0 then
			parts[#parts + 1] = x[1] .. " " .. x[2]
		end
	end
	local summary_line = table.concat(parts, " · ")

	for _, s in ipairs(skipped) do
		lines[#lines + 1] = "ÜBERSPRUNGEN " .. s
	end
	local details = summary_line .. "\n" .. table.concat(lines, "\n")

	if n.warn + n.fail + n.cancel == 0 then
		task:succeed(urls)
		if #skipped > 0 then
			notify("warn", details, 10)
		elseif n.ok == 1 then
			notify("info", (lines[1]:gsub("^OK ", "")))
		else
			notify("info", title .. ": " .. summary_line)
		end
	else
		task:fail(summary_line .. " – Details: Task-Manager (w)")
		if #urls > 0 then
			ya.emit("tasks:update_succeed", { task.id, urls = urls, track = true })
		end
		notify(n.fail + n.cancel > 0 and "error" or "warn", details, 10)
	end
end

-- Zwei Lua-Handles auf DENSELBEN, frischen Abbruch-Token. Einer wird an die Task
-- übergeben (und dabei verbraucht), der andere wird abgefragt. Der Token stammt aus
-- einem eigenen, sofort beendeten ya.async-Rahmen: Ein Abbruch der Task beendet so
-- NICHT diese Coroutine (die sonst ohne Aufräumen verworfen würde), sondern wird
-- per scope:cancelled() erkannt → Prozesse killen, Temp-Datei löschen.
local function scope_pair()
	local tx, rx = ya.chan("oneshot")
	ya.async(function() tx:send { rt.scope(), rt.scope() } end)
	local pair = rx:recv()
	return pair[1], pair[2]
end

local function start(self, st, action)
	pcall(cleanup_stale) -- Reste abgebrochener Yazi-Sitzungen entfernen
	probe_tools()
	S = S or load_state()

	if #st.paths == 0 then
		if st.virtual > 0 then
			notify("warn", "Nur lokale Dateien werden unterstützt (kein SFTP/VFS).")
		else
			notify("warn", "Nichts ausgewählt.")
		end
		return
	end
	st.archives = true
	for _, p in ipairs(st.paths) do
		st.archives = st.archives and detect(basename(p) or "").known
	end

	local T = {}
	if action == "preset" then
		local found
		for _, p in ipairs(presets()) do
			found = found or ((p.id == st.preset or p.name == st.preset or p.key == st.preset) and p or nil)
		end
		if not found then
			notify("error", "Preset nicht gefunden: " .. tostring(st.preset))
			return
		end
		apply_preset(found)
		action = "start"
	elseif action == "pack" then
		action = pack_form(st, T)
	end
	if action == "extract" then
		action = unpack_form(st, T)
	end
	if not action then
		return
	end

	local jobs, skipped, title
	if action == "start" then
		jobs, skipped, title = prepare_pack(st, T)
	else
		jobs, skipped, title = prepare_unpack(st, T, action)
	end
	pcall(save_state)
	if not jobs then
		return
	end

	local scope, task_scope = scope_pair()
	local task = ya.task("custom", { scope = task_scope, progress = true, track = true }):name(title):spawn()
	if not task:acquire() then
		return
	end
	if st.from_selection then
		ya.emit("escape", { select = true })
	end

	local okr, err = pcall(execute, self, task, scope, jobs, skipped, title)
	if not okr then
		task:fail("interner Fehler: " .. tostring(err))
		error(err, 0)
	end
end

-- läuft synchron (UI-Thread): nur Auswahl einsammeln, alles Weitere asynchron
local function collect()
	local tab = cx.active
	local paths, virtual, from_selection = {}, 0, false
	for _, f in pairs(tab.selected) do
		local u = f.url or f -- 26.9: File-Objekte; ältere Versionen: Url
		from_selection = true
		if u.spec.is_virtual then
			virtual = virtual + 1
		else
			paths[#paths + 1] = tostring(u.path)
		end
	end
	if not from_selection then
		local h = tab.current.hovered
		if h then
			if h.url.spec.is_virtual then
				virtual = 1
			else
				paths[1] = tostring(h.url.path)
			end
		end
	end
	table.sort(paths)
	local cwd = tab.current.cwd
	return {
		paths = paths,
		virtual = virtual,
		from_selection = from_selection,
		cwd = (not cwd.spec.is_virtual) and tostring(cwd.path) or nil,
	}
end

local function entry(self, job)
	self.slots = self.slots or { all = 0, heavy = 0 }

	local okc, st = pcall(collect)
	if not okc then
		ya.err("zstd-compress: " .. tostring(st))
		notify("error", "Auswahl nicht lesbar: " .. tostring(st), 10)
		return
	end

	local args = job and job.args or {}
	local action = "pack"
	if args.preset then
		action, st.preset = "preset", tostring(args.preset)
	elseif args[1] == "extract" or args[1] == "test" then
		action = args[1]
	end

	ya.async(function()
		local okr, err = pcall(start, self, st, action)
		if not okr then
			ya.err("zstd-compress: " .. tostring(err))
			notify("error", "Interner Fehler: " .. tostring(err), 10)
		end
	end)
end

-- require("zstd-compress"):setup { max_parallel = 2, max_heavy = 1, presets = { {key, name, format, …} } }
-- Presets mit bereits vergebener Taste ersetzen das eingebaute Preset.
local function setup(_, opts)
	opts = opts or {}
	CFG.max_parallel = tonumber(opts.max_parallel) or CFG.max_parallel
	CFG.max_heavy = tonumber(opts.max_heavy) or CFG.max_heavy
	for _, p in ipairs(opts.presets or {}) do
		if type(p) == "table" and p.key and p.name and FMT[p.format or ""] then
			local replaced = false
			for i, q in ipairs(PRESETS) do
				if q.key == p.key then
					PRESETS[i], replaced = p, true
				end
			end
			if not replaced then
				PRESETS[#PRESETS + 1] = p
			end
		end
	end
end

return { entry = entry, setup = setup, version = VERSION }
