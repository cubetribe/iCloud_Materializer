# iCloud Migration Findings

Stand: 2026-03-20

## Ausgangslage

- Quelle: iCloud Drive unter `~/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding Projekte`
- Ziel: externe Platte unter `/Volumes/2TBCloudDrive/VibeCoding_Local`
- Problem: sehr viele Dateien und Ordner in iCloud Drive, Finder-Kopien haengen, Shell-Zugriff auf `Mobile Documents` ist in dieser Session nicht verlaesslich moeglich
- Ziel waehrend der Session: Projektordner kontrolliert auf externe Platte holen, jeden Teil verifizieren, danach Quelle spaeter verschlanken

## Was sicher funktioniert hat

### 1. Finder kann die iCloud-Quelle lesen, wenn die Shell es nicht kann

- Direkter Shell-Zugriff auf `~/Library/Mobile Documents/...` war aus dieser Session oft mit `Operation not permitted` oder aehnlichen TCC-/File-Provider-Problemen blockiert.
- Finder/AppleScript konnte dieselben Ordner und Dateien trotzdem enumerieren.
- Konsequenz: Finder-basierte Automatisierung war der einzig verlässlich nutzbare Pfad fuer die Quelle.

### 2. Kleine, verifizierte Copy-Chunks funktionieren

- Ganze Projektordner als ein Finder-Copy-Job waren unzuverlaessig.
- Kleine Chunks mit Finder + Staging + Verify haben funktioniert.
- Besonders robust war:
  1. Quelle per Finder enumerieren
  2. in einen Staging-Ordner auf die externe Platte kopieren
  3. Dateianzahl und Byte-Summe mit der Quelle vergleichen
  4. erst dann den Stage an den sichtbaren Zielpfad promoten

### 3. Kleine Finder-Batches statt grosser Sammelkopien

- Grosse Sammel-`duplicate`-Aufrufe haengen oft schon im ersten Batch.
- Kleine Batches oder Einzelfile-Kopien sind viel stabiler.
- Ein konkreter Befund:
  - Root-Dateien eines Projektordners als grosser Finder-Batch: hing
  - dieselben Dateien in kleineren Batches: liefen sauber durch

### 4. Zielseitige Verifikation ueber Count + Bytes ist brauchbar

- Fuer erfolgreiche Chunks war der verlässlichste schnelle Check:
  - Dateianzahl stimmt
  - Gesamt-Bytezahl stimmt
- Das war ausreichend, um kleine und mittlere Unterordner sauber als "gruen" zu markieren.
- Fuer problematische Faelle konnten gezielt einzelne fehlende oder fehlerhafte Dateien nachgezogen und erneut verifiziert werden.

### 5. Teilweise reparierbare Fehlerbilder

- Bei einigen Ordnern fehlten nach einem fast erfolgreichen Lauf nur wenige Dateien.
- Diese liessen sich gezielt nachziehen, statt den gesamten Ordner neu zu kopieren.
- In einem Fall waren Dateien am Ziel als Nullbyte-Dateien vorhanden; auch das liess sich gezielt reparieren.

### 6. Aktuell bereits verifizierte Teilerfolge

Beim Projekt `2Mic1Hal_RAG_WebSite` wurden im verifizierten Zwischenstand erfolgreich kopiert:

- Root-Dateien des Projekts
- `Context`
- `Prototyp_Migration_Analyse`
- `Skalierung`
- `agents`
- `backup`
- `dist`
- `docs`
- `output`
- `prisma`
- `scripts`
- `shared`
- `src`
- `tests`
- `transkript_upload`

Wichtig:

- `__STAGING` bedeutete in der Session immer: verifizierter Zwischenstand, noch nicht final umbenannt
- Nichts wurde aus iCloud geloescht

## Was nicht funktioniert hat

### 1. Direkter Shell-Workflow gegen iCloud Drive war nicht stabil

- `cp`, `rsync`, `find`, `stat`, Python `os.listdir`, direkte Dateizugriffe gegen die iCloud-Quelle waren aus dieser Session nicht verlaesslich.
- `brctl download` war lokal vorhanden, aber fuer die eigentliche Migration in dieser Session nicht belastbar genug.
- Fazit: klassische CLI-Migration direkt gegen `Mobile Documents` war hier nicht die tragfaehige Loesung.

### 2. Ganze Finder-Kopien auf einmal haengen

- Der Finder hing wiederholt bei "Kopieren vorbereiten".
- Ganze Ordner oder sehr grosse Teilbaeume in einem Zug zu kopieren war nicht verlässlich.
- Sichtbarer Nebeneffekt: leere oder halbfertige Zielordner, obwohl Finder noch "arbeitet".

### 3. Fehlgeschlagene Finder-Kopien vergiften Zielordner

- Fehlversuche hinterliessen Resume-/Checkpoint-Metadaten am Ziel.
- Diese Zielordner waren danach teilweise nicht mehr normal nutzbar.
- Konsequenz: kaputte Zielordner mussten quarantänisiert oder neu aufgebaut werden.

### 4. Finder erzeugt zusaetzliche Artefakte

- `.DS_Store`-Dateien wurden am Ziel erzeugt.
- Diese Artefakte haben Verifikationen mehrfach verfälscht, wenn sie nicht explizit ignoriert wurden.
- Konsequenz fuer die App:
  - `.DS_Store` und aehnliche Finder-Artefakte muessen bei der Validierung sauber ausgefiltert werden

### 5. Finder-Ordnerenumeration ist nicht konsistent

- `every folder of entire contents` schlug fuer manche Ordner mit Finder-Fehler `-1728` fehl.
- Die Dateiliste desselben Ordners war in denselben Faellen aber trotzdem lesbar.
- Konsequenz:
  - Die App darf sich nicht nur auf Ordnerenumeration verlassen.
  - Ein Fallback "Verzeichnisliste aus Dateipfaden ableiten" ist noetig.

### 6. Promoten eines Staging-Ordners ist gefaehrlich, wenn das Ziel schon existiert

- Ein `mv` auf einen bereits vorhandenen Zielordner fuehrte nicht zu "ersetzen", sondern zu Merge/Nesting.
- Folge:
  - doppelte Dateizaehlungen
  - verschachtelte `_staging_*`-Ordner innerhalb des eigentlichen Zielordners
- Konsequenz:
  - Vor jeder Promotion muss garantiert sein, dass der Zielpfad wirklich nicht existiert
  - andernfalls erst quarantänisieren und danach sauber promoten

### 7. ZIP-/Archiv-Workflow ist noch nicht fertig validiert

- Die naechste geplante Stufe war:
  1. Ordner lokal verifizieren
  2. aus der verifizierten lokalen Kopie eine ZIP bauen
  3. diese ZIP in iCloud Drive ablegen
  4. erst dann den Originalordner in iCloud entfernen
- Ein erster Archiv-Kopierversuch (`backup.zip`) blieb jedoch noch haengen und wurde abgebrochen.
- Fazit:
  - Das Archivieren ist konzeptionell sinnvoll
  - in dieser Session wurde es aber noch nicht Ende-zu-Ende validiert

## Wichtigste Erkenntnisse fuer eine spaetere App

### 1. Die App braucht einen zustandsbasierten Workflow

Keine "einfach kopieren"-App, sondern ein echter Job-Runner mit Phasen:

1. Quelle enumerieren
2. Download/Hydration pruefen
3. Chunk in Stage kopieren
4. Count/Bytes validieren
5. Ziel promoten
6. optional ZIP erzeugen
7. ZIP validieren
8. Original verschieben/entfernen
9. Status persistieren

### 2. Die App muss chunk-basiert arbeiten

- Nicht den ganzen Ordner auf einmal
- Erst Top-Level-Ordner
- Bei grossen Ordnern auch intern weiter zerlegen
- Jeder Chunk braucht:
  - eigenen Stage
  - eigene Logs
  - eigenen Verify
  - eigene Resume-Faehigkeit

### 3. Die App braucht Recovery fuer kaputte Zwischenstaende

Pflichtfunktionen:

- partielle Ziele erkennen
- `_staging_*`-Reste erkennen
- doppelt gemergte Ziele erkennen
- Finder-Artefakte ignorieren oder bereinigen
- fehlende oder Nullbyte-Dateien gezielt nachziehen koennen

### 4. Die App muss Quelle und Ziel unterschiedlich behandeln

- Quelle: iCloud/File Provider/Finder-seitig
- Ziel: normale Dateisystem-Operationen
- Das ist ein Kernpunkt: dieselben Dateizugriffe funktionieren fuer Quelle und Ziel nicht gleich.

### 5. Die App braucht gute Sichtbarkeit

Wichtig fuer ein Produkt:

- welcher Ordner ist schon vollstaendig lokal
- welcher Chunk ist gerade aktiv
- wie viele Dateien sind sicher verifiziert
- welche Fehler traten auf
- welche Datei haengt gerade
- welche Teilordner fehlen noch

## Kompakte Produkt-These

Das Problem ist real und nicht nur "Bedienfehler". Der Schmerz entsteht aus der Kombination aus:

- iCloud File Provider
- TCC-/Berechtigungsgrenzen
- unzuverlaessigen Finder-Massenkopien
- fehlender Resume-/Verify-Logik
- sehr grossen Dateibaeumen

Eine gute App fuer dieses Problem muesste nicht "magisch schneller" sein, sondern vor allem:

- robuster
- zustandsbasiert
- verifizierbar
- wiederaufnehmbar
- sichtbar im Fehlerfall

Genau darin liegt wahrscheinlich der eigentliche Produktwert.

## Kurzfazit

Die belastbare Erkenntnis aus dieser Session ist:

- Monolithische iCloud-Migrationen sind in diesem Setup unzuverlaessig.
- Chunked Finder-basierte Migration mit expliziter Verifikation funktioniert.
- ZIP als spaetere Reduktionsstrategie ist sinnvoll, aber noch nicht fertig bewiesen.
- Die entscheidende Chance fuer eine App liegt in Orchestrierung, Status, Recovery und Verify, nicht in einem einzelnen "Geheim-Befehl".
