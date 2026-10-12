# zstd-compress.yazi

Yazi-Plugin (≥ 26.9.1): Dateien/Ordner asynchron mit zstd komprimieren —
als abbrechbare Yazi-Task, blockiert die UI nie.

**Version 1.0.0**

## Bedienung

| Taste | Wirkung |
|---|---|
| `c` → `z` | Menü „mit zstd komprimieren“ |
| `1`–`8` | Stufe: zstd -1 / -3 / -6 / -9 / -12 / -15 / -19 / -22 --ultra |
| `s` / `m` / `c` | nur bei Mehrfachauswahl: ein Archiv / je Eintrag eins / abbrechen |

- Datei → `<name>.zst` (Rechte + mtime bleiben), Ordner → `<name>.tar.zst`
- `s` → Namensabfrage, `<name>.tar.zst` im aktuellen Ordner
- Ablauf: Temp-Datei `.yazi-zstd-<id>.part` → Integritätstest → freier Name
  (nie überschreiben, sonst `_1`) → atomarer Rename → Original in den
  Papierkorb (`gio trash`, Fallback `trash-put`)
- Original bleibt, wenn: Fehler, Abbruch, tar-Warnung (Socket, Datei während
  des Lesens geändert …) oder Papierkorb nicht möglich
- Abbruch im Task-Manager (`w` → `x`): Prozesse gekillt, Temp-Datei gelöscht
- Yazi beendet während der Arbeit: `setpriv --pdeathsig` killt tar/zstd;
  Reste werden beim nächsten Aufruf über
  `$XDG_STATE_HOME/yazi/zstd-compress/<pid>.list` entfernt
- Ordner mit Mountpunkt darin werden abgelehnt; Symlinks/Sonderdateien im
  Modus `m` übersprungen
- max. 2 Kompressionen gleichzeitig, davon max. 1 mit Stufe 8 (`-T4`)

## Installation

Empfohlen: `install.sh` (sichert `keymap.toml`/`package.toml`, ersetzt alte
`c z`-Bindings, installiert per `ya pkg`, prüft das Ergebnis, gibt den
Rollback-Befehl aus):

```sh
curl -fsSL https://raw.githubusercontent.com/Teynz/zstd-compress.yazi/main/install.sh | bash
```

Manuell:

```sh
ya pkg add Teynz/zstd-compress
```

`~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = [ "c", "z" ]
run  = "plugin zstd-compress"
desc = "mit zstd komprimieren"
```

Update: `ya pkg upgrade Teynz/zstd-compress`

Abhängigkeiten: `zstd`, GNU `tar`, `du`, `chmod`, `sh`; optional `setpriv`
(util-linux), `gio` (glib2) oder `trash-put`.

## Getestet (Yazi 26.9.1 aus Quellcode, unprivilegierter Benutzer, tmux)

| Fall | Ergebnis |
|---|---|
| Datei / Ordner einzeln | OK, Inhalt + Rechte verifiziert, Original im Papierkorb |
| Namenskollision | `c.txt` → `c_1.txt.zst` |
| Sonderzeichen, führendes `-` | OK |
| `m` mit Symlink, FIFO, Ordner mit Socket | Link/FIFO übersprungen, Socket-Ordner: Archiv ja, Original bleibt |
| Ordner mit unlesbarer Datei | tar Exit 2 → Fehler, keine Reste |
| Ordner mit Mountpunkt | abgelehnt |
| Abbruch im Task-Manager | zstd weg, Temp weg, Original unverändert |
| Yazi beenden während Kompression | zstd stirbt, Reste beim nächsten Aufruf entfernt |
| 2× Stufe 8 gleichzeitig | zweite wartet auf Slot |
| `s` + Name, ungültiger Name, Esc | OK |
| Ziel liegt in ausgewähltem Ordner / doppelte Namen | abgelehnt |
| Papierkorb nicht möglich | Archiv bleibt, Original bleibt, Warnung |
| schreibgeschützter Ordner | Fehler, keine Änderung |
| Datei ändert sich beim Packen (tar Exit 1) | Archiv ja, Original bleibt, Warnung |
| `install.sh` (altes `c z`-Binding, 2. Lauf) | ersetzt, idempotent |

`tests/` enthält die Sandbox-Hilfsskripte (tmux + `ya emit-to`), nicht für den
Produktivbetrieb.
