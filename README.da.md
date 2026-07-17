# Claude Buttons (dansk)

En slank knap-strimmel, der klistrer sig til **Claude desktop-appens** bundbjælke (Windows) og
skriver slash-kommandoer eller tekst ind i chatten, når du klikker. Pin dine mest brugte
kommandoer som ét-kliks-knapper — globalt eller bundet til en bestemt chat.

## Krav

- Windows 10 eller 11
- Claude desktop-appen
- Indbygget **Windows PowerShell 5.1** (følger med Windows; kør ikke under PowerShell 7)

## Installation

```powershell
git clone https://github.com/IncredibleFyrkat/claude-buttons.git
cd claude-buttons
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Eller dobbeltklik på **`install.cmd`**.

Installeren lægger panelet i `%LOCALAPPDATA%\Programs\ClaudeButtons`, installerer `/pin`- og
`/unpin`-skills, og fletter **én** hook (`UserPromptSubmit`) sikkert ind i din
`~/.claude/settings.json` (med backup). **Genstart Claude-appen én gang** bagefter, så skills'ene
indlæses.

### Valgfrit: nedluknings-funktionen

Installeren tilbyder — **slået fra som standard, spørger altid først** — en "Luk PC når færdig"-funktion:
to ekstra skills og en `Stop`-hook, der kan køre `shutdown /s /t 60` (60 sekunder, kan fortrydes),
når en session du selv har armeret slutter. Sig nej, hvis du ikke vil have den.

## Brug

- Skift til Claude-appen — strimlen dukker op i bundbjælken.
- **Højreklik på prik-grebet** → *Pin ny knap* → vælg en kommando (scope vælges med fluebenene øverst).
- **Venstreklik** på en knap for at skrive dens kommando; globale knapper trykker også Enter, chat-knapper lader dig se teksten først.
- **Højreklik på en knap** → omdøb, flyt eller fjern.
- **Position** og **Sprog** ligger i samme grebs-menu. Skift til dansk under *Sprog → Dansk*.

## Fejlsøgning

- **Strimlen sidder skævt efter en app-opdatering** → appens UI er ændret. Se `%LOCALAPPDATA%\claude-buttons.log` og juster de app-afhængige felter i `buttons.json` (`uiaPaneName`, `uiaSidebarName`, `zoneTop`, `zoneBottom`, `fallbackRow`, `stripGap`, `reservedW`). Bed evt. Claude om at "probe appens UIA-træ og opdatere felterne".
- **`/pin` ukendt kommando** → genstart Claude-appen.
- **Intet vises** → strimlen vises kun, når Claude-vinduet er i forgrunden.

## Afinstallation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## Licens

MIT — se [LICENSE](LICENSE).
