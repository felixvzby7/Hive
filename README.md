# Hive – Claude Terminal App

Eine native macOS-App, in der du mehrere [Claude Code](https://claude.com/claude-code)-Sessions in echten Terminals nebeneinander nutzt: mit Session-Verlauf, mehreren Fenstern und Drag & Drop für Dateien und Bilder.

> Inoffizielles Community-Projekt. Nicht mit Anthropic verbunden und nicht von Anthropic unterstützt.

## Funktionen

- **Echte Terminals mit `claude`**: Jede Session ist ein vollwertiges Terminal (auf Basis von [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) und nutzt deinen vorhandenen Claude-Code-Login.
- **Seitenleiste mit allen Sessions**
  - *Dieses Fenster*: die Sessions im aktuellen Fenster
  - *Andere Fenster*: springen oder Session ins aktuelle Fenster holen
  - *Externe Terminals*: Claude-Sessions, die in Terminal, iTerm, VS Code usw. laufen; ein Klick holt die App nach vorne
  - *Verlauf*: frühere Sessions, durchsuchbar, mit einem Klick fortsetzen (`claude --resume`)
- **Geteilte Ansicht**: bis zu 4 Sessions gleichzeitig nebeneinander bzw. im 2×2-Raster
- **Mehrere Fenster** wie bei einem Browser: ⌘N oder Rechtsklick auf das Dock-Symbol → „Neues Fenster“
- **Dateien & Bilder an Claude geben**
  - Dateien, Ordner und Bilder ins Terminal ziehen (auch aus Fotos, Mail oder dem Browser)
  - ⌘V mit einem Screenshot oder im Finder kopierten Dateien in der Zwischenablage
  - 📎-Knopf bzw. ⇧⌘A für eine Dateiauswahl
- **Globales Tastenkürzel** ⌃⌥Space zum Ein- und Ausblenden, plus Symbol in der Menüleiste
- Deutsche Tastaturbelegung: Option funktioniert für `@ [ ] { } | ~`

## Tastenkürzel

| Kürzel | Aktion |
|---|---|
| ⌃⌥Space | App ein-/ausblenden (global) |
| ⌘N | Neues Fenster |
| ⌘T | Neue Session |
| ⌘D | Neue Session daneben |
| ⌘O | Neue Session in einem Ordner |
| ⇧⌘A | Datei anhängen |
| ⌘W / ⇧⌘W | Session beenden / Fenster schließen |
| ⌃⌘S | Seitenleiste ein-/ausblenden |
| ⌘-Klick auf eine Session | Daneben öffnen |

## Voraussetzungen

- macOS 14 (Sonoma) oder neuer
- Ein Claude-Abo (Pro oder Max) oder ein Anthropic-Console-Konto
- Swift-Toolchain: Xcode **oder** nur die Command Line Tools (`xcode-select --install`)

[Claude Code](https://docs.claude.com/en/docs/claude-code) musst du nicht vorher installieren – das übernimmt Hive beim ersten Start.

## Installation

```bash
git clone https://github.com/felixvzby7/Hive.git
cd Hive
./build.sh
```

`build.sh` baut die App, installiert sie nach `/Applications/Hive.app` und startet sie.

### Erster Start

Hive prüft beim Öffnen, ob Claude Code installiert und angemeldet ist. Falls nicht, führt dich eine Willkommensseite durch zwei Schritte:

1. **Claude Code installieren** – führt den offiziellen Installer (`curl -fsSL https://claude.ai/install.sh | bash`) sichtbar in einem Terminal aus. Kein Administrator-Passwort nötig.
2. **Bei Claude anmelden** – startet `claude auth login`; dein Browser öffnet sich zur Anmeldung.

Danach öffnet sich automatisch die erste Session. Ist schon alles eingerichtet, startest du direkt.

Da du die App selbst baust, erscheint keine Gatekeeper-Warnung („nicht verifizierter Entwickler“).

### Eigene App-Kennung

Standardmäßig nutzt Hive die Kennung `io.github.hive-terminal`. Eine eigene setzt du so:

```bash
BUNDLE_ID=com.deinname.hive ./build.sh
```

### Hinweis zur Code-Signatur

Damit macOS erteilte Berechtigungen (z. B. Zugriff auf Schreibtisch oder Dokumente) über Updates hinweg behält, legt `Scripts/setup-signing.sh` beim ersten Build **ein lokales, selbstsigniertes Zertifikat** namens „Hive Local Signing“ in deinem Anmelde-Schlüsselbund an. Es wird nur zum Signieren dieser App auf deinem Mac verwendet. Du kannst es jederzeit in der Schlüsselbundverwaltung löschen. Klappt das Anlegen nicht, wird die App trotzdem gebaut (ad-hoc signiert) – macOS fragt dann nach Updates nur erneut nach Berechtigungen.

## Wie es funktioniert

- Jede Session startet `claude` in einer Login-Shell (`zsh -l -i`), damit dein normaler `PATH` gilt. Hive merkt sich den gefundenen Pfad, sodass eine frische Installation sofort funktioniert.
- Laufende Sessions werden aus `~/.claude/sessions/*.json` gelesen, der Verlauf aus `~/.claude/projects/*/*.jsonl` (Titel, letzter Prompt, Arbeitsordner).
- Bilder ohne Datei (Zwischenablage, Browser, Fotos) werden in `~/Library/Caches/Hive/Attachments` gespeichert und als Pfad eingefügt.

## Projektstruktur

```
Sources/Hive/
  main.swift                 App, Fenster, Menüs, Dock-Menü, Hotkey
  Terminals.swift            Sessions (Tabs), Fenster- und App-Zustand
  Views.swift                SwiftUI-Oberfläche (Seitenleiste, Panes)
  Sessions.swift             Lesen laufender Sessions und des Verlaufs
  Setup.swift                Prüft Installation und Anmeldung von Claude Code
  Onboarding.swift           Willkommensseite für die Ersteinrichtung
  ClaudeTerminalView.swift   Terminal mit Drag & Drop und Bild-Einfügen
Scripts/
  make-icon.swift            Rendert das App-Icon
  setup-signing.sh           Legt das lokale Signatur-Zertifikat an
build.sh                     Bauen, signieren, installieren
```

## Danksagung

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) von Miguel de Icaza (MIT-Lizenz) für die Terminal-Emulation

## Lizenz

[MIT](LICENSE)
