--- @since 26.9.1
--- @sync entry

--[[
zstd-compress.yazi — v1.0.0 (2026-10-12)

Komprimiert Dateien/Ordner mit zstd als abbrechbare Yazi-Task (blockiert die UI nie).

  c z  → Stufe 1–8 → [Mehrfachauswahl: s / m / c] → [s: Archivname]

  Datei  → <name>.zst      reines zstd, Rechte + mtime bleiben erhalten
  Ordner → <name>.tar.zst  tar | zstd
  s      → ein gemeinsames <name>.tar.zst im aktuellen Ordner

Ablauf je Archiv:
  1. Ausgabe in versteckte Temp-Datei .yazi-zstd-<id>.part (gleicher Ordner)
  2. Integritätstest (Datei: zstd -t | Ordner: zstd -dc | tar --list)
  3. Zielname reservieren (nie überschreiben → _1, _2 …) + atomarer Rename
  4. Original in den Papierkorb (gio trash, Fallback trash-put) — nur wenn 1–3
     fehlerfrei waren UND tar nichts gemeldet hat
  Abbruch im Task-Manager oder Fehler → Temp-Datei weg, Original unverändert.
]]

local VERSION = "1.0.0"

local LEVELS = {
	{ on = "1", lvl = 1, hint = "sehr schnell" },
	{ on = "2", lvl = 3, hint = "zstd-Standard" },
	{ on = "3", lvl = 6 },
	{ on = "4", lvl = 9 },
	{ on = "5", lvl = 12 },
	{ on = "6", lvl = 15 },
	{ on = "7", lvl = 19, hint = "max. normal" },
	{ on = "8", lvl = 22, hint = "ultra, langsam, viel RAM" },
}

local THREADS_NORMAL = "-T0" -- alle Kerne
local THREADS_ULTRA = "-T4" -- Stufe 22: ca. 0,8 GiB RAM pro Thread
local MAX_PARALLEL = 2 -- gleichzeitige Kompressionen über alle Tasks
local MAX_PARALLEL_ULTRA = 1 -- davon höchstens eine mit Stufe 22
local POLL = 0.25 -- Sekunden zwischen Status-/Abbruch-Prüfungen
local TMP_PREFIX = ".yazi-zstd-"
local TMP_SUFFIX = ".part"
local TAR_EXCLUDE = ".yazi-zstd-*.part" -- eigene Temp-Dateien nie mitpacken

-- ───────────────────────────── Hilfsfunktionen ─────────────────────────────

local function notify(level, content, timeout)
	ya.notify { title = "zstd", content = content, timeout = timeout or 5, level = level }
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

local function rand_id(seed)
	local s = string.format("%s//%.6f//%d", tostring(seed), ya.time(), math.random(1, 1 << 30))
	return ya.hash(s):sub(1, 10)
end

local function level_args(lvl)
	if lvl > 19 then
		return { "-q", "--ultra", "-" .. lvl, THREADS_ULTRA }
	end
	return { "-q", "-" .. lvl, THREADS_NORMAL }
end

local function level_label(lvl)
	for i, l in ipairs(LEVELS) do
		if l.lvl == lvl then
			return string.format("Stufe %d (-%d)", i, lvl)
		end
	end
	return "-" .. lvl
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

-- ─────────────────────────── Prozess-Steuerung ────────────────────────────
-- Jeder Prozess läuft als  [setpriv --pdeathsig KILL --] sh -c 'exec "$@" 2>"$0"' <errfile> prog …
--  • exec → die PID ist direkt tar/zstd (Abbruch trifft den richtigen Prozess)
--  • stderr landet in einer Datei → keine Pipe, die volllaufen oder Zeilen verlieren kann
--  • pdeathsig → endet Yazi, sterben laufende tar/zstd mit (keine Waisen)

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
-- Wird Yazi während einer Kompression beendet (oder stürzt ab), bleiben die
-- Temp-Datei (.part) und die stderr-Datei liegen. Jede Yazi-Instanz führt daher
-- unter $XDG_STATE_HOME/yazi/zstd-compress/<pid>.list die Pfade ihrer laufenden
-- Temp-Dateien. Beim nächsten Start werden Listen toter Instanzen abgearbeitet.
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
	return b:match("^%.yazi%-zstd%-%x+%.part$") ~= nil or b:match("^yazi%-zstd%-%x+%.err$") ~= nil
end

local function purge_list(file)
	for path in (read_file(file) or ""):gmatch("[^\0]+") do
		if is_ours(path) then
			fs.remove("file", Url(path))
		end
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

-- opts: { stdin = <Stdio|ChildStdout>, stdout = Command.NULL|Command.PIPED }
local function spawn(name, prog, args, opts)
	opts = opts or {}
	local errf = join(errdir(), "yazi-zstd-" .. rand_id(prog) .. ".err")
	inflight(errf, true)
	local a = {}
	if have_setpriv() then
		a = { "--pdeathsig", "KILL", "--", "sh" }
	end
	for _, x in ipairs { "-c", 'exec "$@" 2>"$0"', errf, prog } do
		a[#a + 1] = x
	end
	for _, x in ipairs(args) do
		a[#a + 1] = x
	end
	local c = Command(have_setpriv() and "setpriv" or "sh"):arg(a)
	if opts.stdin then
		c = c:stdin(opts.stdin)
	end
	c = c:stdout(opts.stdout or Command.NULL):stderr(Command.NULL)
	local child, err = c:spawn()
	if not child then
		inflight(errf, false)
		return nil, string.format("%s nicht startbar: %s", prog, tostring(err))
	end
	return { name = name, child = child, errf = errf, err = {}, done = false }
end

local function collect_err(p)
	if not p.errf then
		return
	end
	local s = read_file(p.errf)
	os.remove(p.errf)
	inflight(p.errf, false)
	p.errf = nil
	for line in (s or ""):gmatch("[^\r\n]+") do
		-- Fortschrittszeilen von zstd --progress sind keine Meldungen
		local is_progress = line:match("^%s*$") or line:match("^Read:") or line:match("^%(L%d+%)")
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
			pcall(on_tick)
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

-- von zstd bereits verarbeitete Eingabe-Bytes (für die %-Anzeige).
-- Quelle: letzte "Read: <n> <Einheit>"-Zeile von `zstd --progress` in der stderr-Datei.
-- (Gelesene Bytes laut /proc/<pid>/io wären ungenau: zstd puffert mit -T0 weit voraus.)
local UNITS = { B = 1, KiB = 1024, MiB = 1024 ^ 2, GiB = 1024 ^ 3, TiB = 1024 ^ 4 }

local function zstd_consumed(errf)
	local f = errf and io.open(errf, "rb")
	if not f then
		return nil
	end
	local size = f:seek("end") or 0
	f:seek("set", math.max(0, size - 512))
	local s = f:read("a") or ""
	f:close()
	local num, unit
	for n, u in s:gmatch("Read:%s*([%d%.]+)%s*(%a+)") do
		num, unit = n, u
	end
	local m = unit and UNITS[unit]
	if not m or not tonumber(num) then
		return nil
	end
	return math.floor(tonumber(num) * m)
end

-- ─────────────────────────────── Dateisystem ───────────────────────────────

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

local function du_bytes(path, scope)
	local p = spawn("du", "du", { "-s", "-b", "--", path }, { stdout = Command.PIPED })
	if not p then
		return 0
	end
	if supervise({ p }, scope) then
		return 0
	end
	local line = p.child:read_line()
	local n = line and line:match("^(%d+)")
	return n and tonumber(n) or 0
end

local function remove_file(path) fs.remove("file", Url(path)) end

-- reserviert atomar einen freien Namen: <stem><suffix>, sonst <stem>_N<suffix>
local function reserve(dir, stem, suffix)
	for i = 0, 9999 do
		local name = i == 0 and (stem .. suffix) or string.format("%s_%d%s", stem, i, suffix)
		local fd, err = fs.access():write(true):create_new(true):open(Url(join(dir, name)))
		if fd then
			return join(dir, name), name
		elseif not err or err.kind ~= "AlreadyExists" then
			return nil, nil, tostring(err)
		end
	end
	return nil, nil, "kein freier Dateiname gefunden"
end

-- verschiebt in den Papierkorb (nie endgültig löschen).
-- `path` ist immer absolut ("/…"): gio braucht/verträgt kein "--" (GOption lässt
-- es bei Namen mit führendem "-" als Datei-Argument stehen).
local function trash(path)
	local tried = {}
	for _, t in ipairs { { "gio", { "trash", path } }, { "trash-put", { "--", path } } } do
		local p, err = spawn(t[1], t[1], t[2])
		if p then
			supervise({ p })
			if ok(p) then
				return true
			end
			tried[#tried + 1] = describe(p)
		else
			tried[#tried + 1] = err
		end
	end
	return false, table.concat(tried, "; ")
end

-- ─────────────────────────── Kompressions-Slots ────────────────────────────

local function slot_acquire(slots, ultra, scope, task)
	local logged = false
	while slots.all >= MAX_PARALLEL or (ultra and slots.ultra >= MAX_PARALLEL_ULTRA) do
		if scope:cancelled() then
			return false
		end
		if not logged then
			task:log("Warte auf freien Kompressions-Slot …")
			logged = true
		end
		ya.sleep(0.5)
	end
	slots.all = slots.all + 1
	if ultra then
		slots.ultra = slots.ultra + 1
	end
	return true
end

local function slot_release(slots, ultra)
	slots.all = math.max(0, slots.all - 1)
	if ultra then
		slots.ultra = math.max(0, slots.ultra - 1)
	end
end

-- ───────────────────────────────── Ein Job ─────────────────────────────────
-- job = { kind = "file"|"tar", dir, stem, suffix, size, srcs = { {path, dir, name, mode, …} } }
-- Rückgabe: { state = "ok"|"warn"|"fail"|"cancel", msg, url, name, out_size }

local function compress(job, lvl, scope, progress)
	local tmp = join(job.dir, TMP_PREFIX .. rand_id(job.srcs[1].path) .. TMP_SUFFIX)
	inflight(tmp, true)
	local function bail(msg)
		inflight(tmp, false)
		return { state = "fail", msg = msg }
	end
	local zargs = level_args(lvl)
	zargs[#zargs + 1] = "--progress" -- Fortschritt → stderr-Datei (trotz -q)
	local procs, z

	if job.kind == "file" then
		for _, x in ipairs { "-o", tmp, "--", job.srcs[1].path } do
			zargs[#zargs + 1] = x
		end
		local err
		z, err = spawn("zstd", "zstd", zargs)
		if not z then
			return bail(err)
		end
		procs = { z }
	else
		local targs = { "--create", "--file=-", "--exclude=" .. TAR_EXCLUDE }
		for _, s in ipairs(job.srcs) do
			targs[#targs + 1] = "--directory=" .. s.dir
			targs[#targs + 1] = "--add-file=" .. s.name
		end
		local t, err = spawn("tar", "tar", targs, { stdout = Command.PIPED })
		if not t then
			return bail(err)
		end
		zargs[#zargs + 1] = "-o"
		zargs[#zargs + 1] = tmp
		local zerr
		z, zerr = spawn("zstd", "zstd", zargs, { stdin = t.child:take_stdout() })
		if not z then
			kill_all { t }
			return bail(zerr)
		end
		procs = { t, z }
	end

	-- Fortschritt = von zstd verarbeitete Eingabe-Bytes
	local reported = 0
	local function report(n)
		n = math.min(n, job.size)
		if n > reported then
			progress(n - reported)
			reported = n
		end
	end
	local function tick()
		local n = zstd_consumed(z.errf)
		if n then
			report(n)
		end
	end

	local function failed(state, msg)
		remove_file(tmp)
		inflight(tmp, false)
		report(job.size)
		return { state = state, msg = msg }
	end

	if supervise(procs, scope, tick) then
		return failed("cancel", "abgebrochen")
	end

	local tar_warn = nil
	if job.kind == "tar" then
		local t, z = procs[1], procs[2]
		if not ok(z) then
			return failed("fail", describe(z) .. (ok(t) and "" or "; " .. describe(t)))
		elseif t.status and t.status.code == 1 then
			-- GNU tar Exit 1 = Datei während des Lesens geändert → Archiv gültig, Original bleibt
			tar_warn = describe(t)
		elseif not ok(t) then
			return failed("fail", describe(t))
		elseif #t.err > 0 then
			tar_warn = tail(t.err, 3)
		end
	elseif not ok(procs[1]) then
		return failed("fail", describe(procs[1]))
	end
	report(job.size)

	-- Integritätstest
	local vprocs
	if job.kind == "file" then
		local v, err = spawn("zstd -t", "zstd", { "-t", "-q", "--", tmp })
		if not v then
			return failed("fail", err)
		end
		vprocs = { v }
	else
		local d, err = spawn("zstd -d", "zstd", { "-d", "-c", "-q", "--", tmp }, { stdout = Command.PIPED })
		if not d then
			return failed("fail", err)
		end
		local l, lerr = spawn("tar --list", "tar", { "--list", "--file=-" }, { stdin = d.child:take_stdout() })
		if not l then
			kill_all { d }
			return failed("fail", lerr)
		end
		vprocs = { d, l }
	end
	if supervise(vprocs, scope) then
		return failed("cancel", "abgebrochen (während Test)")
	end
	for _, p in ipairs(vprocs) do
		if not ok(p) then
			return failed("fail", "Integritätstest fehlgeschlagen: " .. describe(p))
		end
	end

	-- tar-Archive: Rechte nie offener als die Quellen (ohne x-Bits)
	if job.kind == "tar" then
		local g = 54 -- 0o066
		for _, s in ipairs(job.srcs) do
			g = g & (s.mode or 0)
		end
		local c = spawn("chmod", "chmod", { string.format("%o", 384 | g), "--", tmp }) -- 0o600 | g
		if c then
			supervise({ c })
		end
	end

	if scope:cancelled() then
		return failed("cancel", "abgebrochen (vor dem Umbenennen)")
	end

	local final, final_name, rerr = reserve(job.dir, job.stem, job.suffix)
	if not final then
		return bail(string.format("Zielname nicht reservierbar (%s); Archiv liegt als %s", rerr, tmp))
	end
	local renamed, mverr = fs.rename(Url(tmp), Url(final))
	if not renamed then
		remove_file(final)
		return bail(string.format("Umbenennen fehlgeschlagen (%s); Archiv liegt als %s", tostring(mverr), tmp))
	end
	inflight(tmp, false)

	local cha = fs.cha(Url(final), false)
	local res = { state = "ok", url = final, name = final_name, out_size = cha and cha.len or 0 }

	if tar_warn then
		res.state, res.msg = "warn", "Original NICHT entfernt – " .. tar_warn
		return res
	elseif scope:cancelled() then
		res.state, res.msg = "warn", "Abbruch nach Fertigstellung – Original bleibt"
		return res
	end

	local failed_trash = {}
	for _, s in ipairs(job.srcs) do
		local t_ok, t_err = trash(s.path)
		if not t_ok then
			failed_trash[#failed_trash + 1] = s.name .. " (" .. t_err .. ")"
		end
	end
	if #failed_trash > 0 then
		res.state, res.msg = "warn", "nicht in den Papierkorb: " .. table.concat(failed_trash, ", ")
	else
		res.msg = "Original im Papierkorb"
	end
	return res
end

-- ────────────────────────────── Vorbereitung ───────────────────────────────

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

local function ask_name(default)
	local value = default
	while true do
		local v, event = ya.input {
			title = "Archivname (.tar.zst wird ergänzt):",
			value = value,
			pos = { "top-center", y = 3, w = 60 },
		}
		if event ~= 1 then
			return nil
		end
		v = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
		v = v:gsub("%.tar%.zst$", ""):gsub("%.tzst$", "")
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

-- Abfragen; liefert jobs, skipped, lvl oder nil (abgebrochen/nichts zu tun)
local function prepare(st)
	if #st.paths == 0 then
		if st.virtual > 0 then
			notify("warn", "Nur lokale Dateien werden unterstützt (kein SFTP/VFS).")
		else
			notify("warn", "Nichts zum Komprimieren ausgewählt.")
		end
		return nil
	end

	local cands = {}
	for i, l in ipairs(LEVELS) do
		local hint = l.hint and (" · " .. l.hint) or ""
		cands[i] = { on = l.on, desc = string.format("zstd -%d%s", l.lvl, hint) }
	end
	local li = ya.which { cands = cands, silent = false }
	if not li then
		return nil
	end
	local lvl = LEVELS[li].lvl

	local mode = "m"
	if #st.paths > 1 then
		local mi = ya.which {
			cands = {
				{ on = "s", desc = string.format("ein Archiv für alle %d Einträge (single)", #st.paths) },
				{ on = "m", desc = string.format("%d einzelne Archive (multiple)", #st.paths) },
				{ on = "c", desc = "abbrechen (cancel)" },
			},
			silent = false,
		}
		if mi == 1 then
			mode = "s"
		elseif mi ~= 2 then
			return nil
		end
	end

	local items, skipped = stat_items(st.paths)
	if st.virtual > 0 then
		skipped[#skipped + 1] = st.virtual .. " Einträge auf VFS/SFTP (nicht unterstützt)"
	end

	local jobs = {}
	if mode == "s" then
		if #skipped > 0 then
			notify("error", "Abbruch – " .. table.concat(skipped, "; "), 8)
			return nil
		elseif not st.cwd then
			notify("error", "Abbruch – aktueller Ordner ist kein lokales Verzeichnis.")
			return nil
		end
		local seen = {}
		for _, it in ipairs(items) do
			if seen[it.name] then
				notify("error", "Abbruch – Name doppelt im Archiv: " .. it.name, 8)
				return nil
			elseif it.kind == "dir" and inside(st.cwd, it.path) then
				notify("error", "Abbruch – das Archiv läge in „" .. it.name .. "“, das danach im Papierkorb landet.", 8)
				return nil
			end
			seen[it.name] = true
		end
		local name = ask_name(basename(st.cwd) or "archiv")
		if not name then
			return nil
		end
		jobs[1] = { kind = "tar", dir = st.cwd, stem = name, suffix = ".tar.zst", srcs = items }
	else
		for _, it in ipairs(items) do
			if it.kind == "file" then
				local stem, ext = split_ext(it.name)
				jobs[#jobs + 1] = { kind = "file", dir = it.dir, stem = stem, suffix = ext .. ".zst", srcs = { it } }
			elseif it.kind == "dir" then
				jobs[#jobs + 1] = { kind = "tar", dir = it.dir, stem = it.name, suffix = ".tar.zst", srcs = { it } }
			elseif it.kind == "link" then
				skipped[#skipped + 1] = it.name .. ": symbolischer Link"
			else
				skipped[#skipped + 1] = it.name .. ": Sonderdatei (FIFO/Socket/Gerät)"
			end
		end
	end

	if #jobs == 0 then
		notify("warn", "Nichts zu tun – " .. table.concat(skipped, "; "), 8)
		return nil
	end
	return jobs, skipped, lvl
end

-- ──────────────────────────────── Ausführung ───────────────────────────────

local function execute(self, task, scope, jobs, skipped, lvl, title)
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
				for _, mp in ipairs(mps) do
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
		workload = workload + job.size
	end
	if workload > 0 then
		task:progress { workload = workload }
	end

	local ultra = lvl > 19
	local n = { ok = 0, warn = 0, fail = 0, cancel = 0 }
	local urls, lines = {}, {}
	for _, job in ipairs(jobs) do
		local res
		if scope:cancelled() then
			res = { state = "cancel", msg = "abgebrochen" }
		elseif job.blocked then
			res = { state = "fail", msg = job.blocked }
		elseif not slot_acquire(self.slots, ultra, scope, task) then
			res = { state = "cancel", msg = "abgebrochen (Warteschlange)" }
		else
			local okc, r = pcall(compress, job, lvl, scope, function(d) task:progress { processed = d } end)
			slot_release(self.slots, ultra)
			res = okc and r or { state = "fail", msg = "interner Fehler: " .. tostring(r) }
		end

		local line
		if res.state == "ok" or res.state == "warn" then
			urls[#urls + 1] = Url(res.url)
			local ratio = job.size > 0 and string.format(" (%.1f %%)", res.out_size / job.size * 100) or ""
			line = string.format(
				"%s %s · %s → %s%s · %s",
				res.state == "ok" and "OK" or "WARNUNG",
				res.name,
				fmt_size(job.size),
				fmt_size(res.out_size),
				ratio,
				res.msg
			)
			task:progress(res.state == "ok" and { success = 1 } or { failed = 1 })
		else
			local tag = res.state == "cancel" and "ABGEBROCHEN" or "FEHLER"
			line = string.format("%s %s%s · %s", tag, job.stem, job.suffix, res.msg)
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
	local summary = table.concat(parts, " · ")

	for _, s in ipairs(skipped) do
		lines[#lines + 1] = "ÜBERSPRUNGEN " .. s
	end
	local details = summary .. "\n" .. table.concat(lines, "\n")

	if n.warn + n.fail + n.cancel == 0 then
		task:succeed(urls)
		if #skipped > 0 then
			notify("warn", details, 10)
		elseif n.ok == 1 then
			notify("info", (lines[1]:gsub("^OK ", "")))
		else
			notify("info", title .. ": " .. summary)
		end
	else
		task:fail(summary .. " – Details: Task-Manager (w)")
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

local function run(self, st)
	pcall(cleanup_stale) -- Reste abgebrochener Yazi-Sitzungen entfernen
	local jobs, skipped, lvl = prepare(st)
	if not jobs then
		return
	end

	local label = level_label(lvl)
	local title = #jobs == 1 and string.format("zstd %s: %s%s", label, jobs[1].stem, jobs[1].suffix)
		or string.format("zstd %s: %d Archive", label, #jobs)

	local scope, task_scope = scope_pair()
	local task = ya.task("custom", { scope = task_scope, progress = true, track = true }):name(title):spawn()
	if not task:acquire() then
		return
	end
	if st.from_selection then
		ya.emit("escape", { select = true })
	end

	local okr, err = pcall(execute, self, task, scope, jobs, skipped, lvl, title)
	if not okr then
		task:fail("interner Fehler: " .. tostring(err))
		error(err, 0)
	end
end

-- ──────────────────────────────── Einstieg ─────────────────────────────────

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
	local cwd = tab.current.cwd
	return {
		paths = paths,
		virtual = virtual,
		from_selection = from_selection,
		cwd = (not cwd.spec.is_virtual) and tostring(cwd.path) or nil,
	}
end

local function entry(self)
	self.slots = self.slots or { all = 0, ultra = 0 }

	local okc, st = pcall(collect)
	if not okc then
		ya.err("zstd-compress: " .. tostring(st))
		notify("error", "Auswahl nicht lesbar: " .. tostring(st), 10)
		return
	end

	ya.async(function()
		local okr, err = pcall(run, self, st)
		if not okr then
			ya.err("zstd-compress: " .. tostring(err))
			notify("error", "Interner Fehler: " .. tostring(err), 10)
		end
	end)
end

return { entry = entry, version = VERSION }
