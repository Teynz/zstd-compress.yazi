# zstd-compress.yazi

> [!WARNING]
> **Dieses Repository ist vollständig KI-generiert.** Der gesamte Code, die
> Tests, die Skripte und die Dokumentation wurden von Claude (Anthropic)
> geschrieben. Der Eigentümer hat sie beauftragt und geprüft, aber nicht selbst
> geschrieben. Ein Mensch hat den Quelltext nicht zeilenweise durchgesehen.
> Nutzung auf eigenes Risiko; Original-Dateien werden nur im Papierkorb-Modus
> verschont, Details unter „Sicherheit des Ablaufs“.

Yazi-Plugin (≥ 26.9.1, Linux): Archive **packen, entpacken und testen** — komplett
in der Yazi-Oberfläche, als abbrechbare Task mit Fortschritt im Task-Manager (`w`).

**Version 2.0.0** · Der Name ist historisch: v1 konnte nur zstd.

## Bedienung

| Taste | Wirkung |
|---|---|
| `c` `z` | Formular „Komprimieren“ für die Auswahl (oder die Datei unter dem Cursor) |
| `c` `x` | Formular „Entpacken“ (auch: `c z` → `X`, wenn nur Archive gewählt sind) |
| `Enter` | Start mit den angezeigten Einstellungen (= die vom letzten Mal) |
| `1`–`5`, `b` | Preset sofort starten |
| jede andere Zeile | Einstellung ändern, das Formular bleibt offen |
| `Esc` | abbrechen |

Jede Zeile des Formulars zeigt Taste, Einstellung und aktuellen Wert. Die
Einstellungen werden pro Format gemerkt (`settings.ini`, siehe unten).

### Formular „Komprimieren“

| Taste | Einstellung |
|---|---|
| `f` | Format (nur Formate, deren Werkzeug installiert ist) |
| `l` `t` `w` `e` `c` `s` … | Optionen des Formats: Stufe, Threads, Long-Range, Extrem, Verfahren, Solid … |
| `x` | Zusatz-Argumente für den Kompressor (frei, durch Leerzeichen getrennt) |
| `k` | Passwort (7z, zip) — wird zweimal abgefragt, nie gespeichert, nie in der Kommandozeile |
| `a` | Danach: Original **behalten** / in den **Papierkorb** / **endgültig löschen** (mit Rückfrage) |
| `m` | Mehrfachauswahl: je Eintrag ein Archiv / ein gemeinsames Archiv / beim Start fragen |
| `o` | Zielordner (Standard: neben der Quelle) |
| `E` | Ausschließen (Muster, z. B. `.git *.o node_modules`) |
| `T` | Zusatz-Argumente für tar (z. B. `--xattrs --acls --one-file-system`) |
| `i` | Einzeldatei in tar packen (`foo.tar.zst` statt `foo.txt.zst`) |
| `D` | Datum an den Namen hängen (`name_2026-11-16_2210.tar.zst`) |
| `N` | Schonend: Werkzeuge mit `nice 19` starten |
| `v` | Integritätstest (ist immer an, sobald das Original entfernt werden soll) |
| `C` | zusätzlich `<archiv>.sha256` schreiben |
| `P` | Presets: aktuelle Einstellungen speichern / eigenes Preset löschen |

Bei **mehreren** gewählten Einträgen muss man sich entscheiden (Zeile `m` oder
Rückfrage beim Start):

- `m` – je Eintrag ein Archiv, benannt nach der Quelle
- `s` – ein gemeinsames Archiv, der Name wird abgefragt

### Formate

| Format | Endung (Datei / Ordner) | Werkzeug | Stufen | weitere Optionen |
|---|---|---|---|---|
| Zstandard | `.zst` / `.tar.zst` | `zstd` | −7 … 22 (ab 20 automatisch `--ultra`, negativ = `--fast`) | Threads, `--long` 27–31 |
| xz (LZMA2) | `.xz` / `.tar.xz` | `xz` | 0 … 9 | Extrem (`-e`), Threads |
| LZMA (alt) | `.lzma` / `.tar.lzma` | `xz --format=lzma` | 0 … 9 | Extrem |
| gzip (Deflate) | `.gz` / `.tar.gz` | `pigz`, sonst `gzip` | 1 … 9 | Threads (nur pigz) |
| bzip2 | `.bz2` / `.tar.bz2` | `bzip2` | 1 … 9 | |
| LZ4 | `.lz4` / `.tar.lz4` | `lz4` | 1 … 12 | |
| Brotli | `.br` / `.tar.br` | `brotli` | 0 … 11 | |
| lzip | `.lz` / `.tar.lz` | `lzip` | 0 … 9 | |
| tar | `.tar` | `tar` | – | |
| 7-Zip | `.7z` | `7zz` / `7z` | 0 … 9 | Verfahren LZMA2/LZMA/PPMd/BZip2/Deflate, Solid, Threads, Passwort, Dateinamen verschlüsseln, Symlinks, Teilen |
| ZIP | `.zip` | `7zz` / `7z` | 0 … 9 | Verfahren Deflate/Deflate64/BZip2/LZMA/PPMd, AES256 oder ZipCrypto, Passwort, Symlinks, Windows-Namen prüfen, Teilen |

### Presets

| Taste | Name (`--preset=`) | Inhalt |
|---|---|---|
| `1` | `zstd-3` | zstd -3 |
| `2` | `zstd-19` | zstd -19 |
| `3` | `zstd-22` | zstd -22 `--ultra` |
| `4` | `xz-6` | xz -6 (LZMA2) |
| `5` | `7z-5` | 7z, LZMA2, Stufe 5 |
| `b` | `backwordscompability` | siehe unten |
| `6`–`0` | eigene | über `P` → `s` gespeichert |

**`backwordscompability`** erzeugt ein `.zip`, das der Windows-Explorer, das
macOS-Archivprogramm und `unzip` ohne Zusatzsoftware öffnen:

- nur Deflate (bzw. unkomprimiert bei winzigen Dateien), Stufe 6
- Dateinamen als UTF-8 gekennzeichnet (Umlaute)
- Symlinks werden aufgelöst (als normale Dateien gespeichert), nicht geteilt
- falls ein Passwort gesetzt wird: ZipCrypto statt AES (AES kann der Explorer nicht)
- vor dem Start werden Namen gemeldet, die Windows nicht anlegen kann
  (`< > : " | ? * \`, Punkt/Leerzeichen am Ende, `CON`, `NUL`, `COM1` …) — mit Rückfrage

Was kein Preset garantieren kann: Namen, die sich nur in Groß-/Kleinschreibung
unterscheiden, und Pfade über 260 Zeichen sind unter Windows weiterhin ein Problem.

### Formular „Entpacken“

| Taste | Einstellung |
|---|---|
| `Enter` | entpacken |
| `t` | nur testen (Archiv vollständig lesen, nichts schreiben) |
| `u` | Unterordner anlegen: nur wenn nötig (Archiv hat mehrere Einträge) / immer |
| `o` | Zielordner (Standard: neben dem Archiv) |
| `a` | Danach: Archiv behalten / Papierkorb / endgültig löschen |

Stream-Formate und `tar.*` laufen über die Werkzeuge aus der Tabelle, alles andere
(zip, 7z, rar, iso, jar, geteilte `.001` …) über 7-Zip. Passwortgeschützte Archive
fragen das Passwort ab (bei falschem Passwort erneut). Vorhandene Dateien werden
nie überschrieben (`name_1`, `name_2` …).

## Sicherheit des Ablaufs

1. Ausgabe in eine versteckte Temp-Datei `.yazi-compress-<id>.part` im Zielordner
   (nur für den Besitzer lesbar)
2. Integritätstest: das fertige Archiv wird vollständig dekomprimiert bzw. `7z t`
3. freien Namen reservieren (nie überschreiben, sonst `_1`) → atomarer Rename
4. erst dann das Original behandeln (behalten / Papierkorb / löschen)

Das Original bleibt **immer**, wenn: Fehler, Abbruch, Warnung eines Werkzeugs
(Datei während des Lesens geändert, Socket, unlesbare Datei …) oder Papierkorb
nicht möglich. Abbruch im Task-Manager (`w` → `x`): Prozesse werden beendet,
Temp-Dateien gelöscht. Wird Yazi während der Arbeit beendet, sterben die Werkzeuge
mit (`setpriv --pdeathsig`); was trotzdem übrig bleibt (Prozesse, Temp-Dateien),
räumt der nächste Aufruf über `$XDG_STATE_HOME/yazi/zstd-compress/<pid>.list` auf.

Weitere Grenzen: Ordner mit einem Mountpunkt darin werden abgelehnt; Symlinks und
Sonderdateien werden bei „je Eintrag ein Archiv“ übersprungen; nur lokale Dateien
(kein SFTP/VFS). Gleichzeitig laufen höchstens 2 Jobs, davon höchstens einer
speicherhungrig (zstd ≥ 20, `--long` ≥ 30, xz -9, 7z 9).

## Installation

Empfohlen: `install.sh` (sichert `keymap.toml`/`package.toml`, trägt `c z` und —
falls frei — `c x` ein, installiert per `ya pkg`, prüft das Ergebnis, gibt den
Rollback-Befehl aus):

```sh
curl -fsSL https://raw.githubusercontent.com/Teynz/zstd-compress.yazi/main/install.sh | bash
```

Manuell: `ya pkg add Teynz/zstd-compress` und in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = [ "c", "z" ]
run  = "plugin zstd-compress"
desc = "Komprimieren / Archiv erstellen"

[[mgr.prepend_keymap]]
on   = [ "c", "x" ]
run  = "plugin zstd-compress extract"
desc = "Archiv entpacken / testen"
```

Weitere Aufrufe für eigene Tasten:

```toml
run = "plugin zstd-compress test"                             # nur testen
run = "plugin zstd-compress -- --preset=backwordscompability" # Preset ohne Formular
run = "plugin zstd-compress -- --preset=zstd-19"
```

Abhängigkeiten: `tar` (GNU), `sh`, `du`, `chmod`, `touch`, `find`; je Format das
Werkzeug aus der Tabelle (fehlende Formate werden nicht angeboten); optional
`setpriv` (util-linux), `gio` (glib2) oder `trash-put`, `sha256sum`, `nice`.
Unter Arch/CachyOS: `pacman -S zstd xz 7zip pigz lz4 brotli lzip`.

## Konfiguration (optional)

`~/.config/yazi/init.lua`:

```lua
require("zstd-compress"):setup {
	max_parallel = 2, -- gleichzeitige Jobs
	max_heavy = 1,    -- davon speicherhungrige
	presets = {       -- eigene Presets; gleiche Taste ersetzt ein eingebautes
		{ key = "9", id = "backup", name = "Backup xz", format = "xz", level = 9, extreme = true, after = "keep" },
	},
}
```

Zuletzt benutzte Werte und im Formular gespeicherte Presets liegen in
`$XDG_STATE_HOME/yazi/zstd-compress/settings.ini` (Klartext, löschbar).

## Ein Format ergänzen

Ein Format ist ein Eintrag in der Tabelle `FORMATS` in `main.lua` — der Ablauf
(Temp-Datei, Test, Rename, Fortschritt, Abbruch) ist für alle gleich:

```lua
{
	id = "lzo", key = "o", name = "lzop", ext = ".lzo", tars = { ".tzo" },
	kind = "stream",                 -- liest stdin, schreibt stdout
	bin = { "lzop" },
	opts = { "level", "extra" },     -- Formularzeilen (siehe OPT)
	over = { level = { min = 1, max = 9, def = 3 } },
	pack = function(o) return { "-c", "-" .. o.level } end,
	unpack = { "-d", "-c" },
},
```

Entpacken, Testen und die Endungs-Erkennung (`.lzo`, `.tar.lzo`, `.tzo`) ergeben
sich daraus automatisch.

## Tests

```sh
lua5.4 tests/unit.lua main.lua   # reine Funktionen
sudo tests/run.sh                # echte Yazi-Instanz in tmux, Benutzer "tester"
```

`tests/run.sh` (YB = Ordner mit `yazi` und `ya`) prüft u. a.:

| Fall | Ergebnis |
|---|---|
| jedes Format, Datei + Ordner | Inhalt identisch zum Original (mit Fremdwerkzeug entpackt) |
| alle 22 Archive wieder entpacken | identisch, keine Überschreibung |
| 7z mit Passwort + verschlüsselten Namen | nur mit Passwort lesbar; Entpacken fragt nach |
| Teilen in 100-MiB-Stücke | `.001 …`, als Ganzes testbar und entpackbar |
| `--preset=backwordscompability` | Windows-Namen-Warnung, zip mit Store/Deflate |
| ein gemeinsames Archiv + Papierkorb | Originale im Papierkorb |
| unlesbare Datei / Mountpunkt / Socket | Fehler bzw. Warnung, Original bleibt, keine Reste |
| Abbruch im Task-Manager | Prozess weg, Temp-Datei weg, Original unverändert |

Von Hand zusätzlich geprüft: Fortschritt für Datei (Leseposition), Ordner
(tar-Checkpoints) und 7-Zip (Prozent); endgültiges Löschen mit Rückfrage; eigene
Presets speichern/löschen und `setup()`; Sonderzeichen, führendes `-`, `*`/`?`
und Umlaute in Namen; Aufräumen nach hart beendetem Yazi.

## TODO

- [ ] **Archive als Ordner einhängen und ändern.** Anforderungen: stabil und
  wartungsarm. Zu klären: eigene Lösung oder Anbindung an fuse-archive /
  archivemount, Schreibzugriff ja/nein, Verhalten bei Abbruch.
- [ ] **Formatwahl über Namenseingabe** (z. B. `x.tar.zst` wählt das Format).
  Anforderungen sind noch zu klären (Zusammenspiel mit dem Formular,
  Standardwerte, Verhalten bei unbekannter Endung).
- [ ] **Task-Manager-Fix:** Die Fortschrittsanzeige im Task-Manager (`w`)
  funktioniert nicht zuverlässig. Zu prüfen: PID/Stdin-Messung über
  `/proc/<pid>/fdinfo/0`, verschluckte Fehler in `pcall`, stille Rückkehr bei
  `acquire()`, Zählung von Warnungen als „failed“, Skalen bei tar und 7z.

## Nicht enthalten

- Dateien zu einem bestehenden Archiv hinzufügen
- `.rar` erzeugen (proprietär; Entpacken geht über 7-Zip)
- Umpacken von einem Format in ein anderes in einem Schritt
