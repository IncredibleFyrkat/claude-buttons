# Claude Buttons (dansk)

En slank knap-strimmel, der klistrer sig til **Claude desktop-appens** bundbjælke (Windows) og
skriver slash-kommandoer eller tekst ind i chatten, når du klikker. Pin dine mest brugte
kommandoer som ét-kliks-knapper — globalt eller bundet til en bestemt chat.

*(English README — den kanoniske: [README.md](README.md).)*

## Funktioner

- **Pin en hvilken som helst kommando** som pille-knap — enten fra en højrekliksmenu på strimlen (uden om Claude) eller via `/pin`-skillen.
- **Global eller per-chat.** Per-chat-knapper vises kun, når den chat er på skærmen, og auto-sender aldrig (de indsætter teksten, så du ser den først).
- **Ikon-knapper** (`"icon": "power"`) i samme størrelse som appens mic-knap — Windows' indbyggede Segoe Fluent Icons, ingen downloads.
- **On/off-toggle-knapper** (`"toggle": true`) der lyser, mens de er tændt; `stateGlob` kan spejle en filsystem-tilstand, så knappen altid viser sandheden.
- **Lange standard-prompts:** en knaps tekst kan være en hel prompt; lang/multiline tekst indsættes atomisk via clipboard (dit tidligere clipboard gendannes).
- **Multi-pane:** i split-/grid-visning får hver chat-pane sin egen strimmel — globale knapper alle steder, chat-knapper under deres egen pane.
- **To-kliks bekræftelse** på destruktive knapper; **EN/DA** UI; tooltips; fri placering.
- **Robust:** alt app-afhængigt (accessibility-navne, zoner) kan rettes i `buttons.json` uden kodeændring, så en app-opdatering degraderer pænt.

## Krav

- Windows 10 eller 11
- Claude desktop-appen + Claude Code (skills/hooks)
- Indbygget **Windows PowerShell 5.1** (følger med Windows; kør ikke under PowerShell 7)
- Node.js — kun til den valgfri shutdown-funktion

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

### Valgfrit: shutdown-on-done (kræver Node.js)

Installeren tilbyder — **slået fra som standard, spørger altid først** — "shutdown-on-done"-motoren
(bidraget af Rasmus): sluk PC'en, når en chat er HELT færdig med sit arbejde. Modellen dømmer
"færdig" (baggrundsopgaver inkl.) og armerer først den ægte nedlukning som den allersidste handling
i sin afsluttende besked — så PC'en slukker aldrig midt i arbejdet. 60 sekunders frist; `shutdown -a`
annullerer. Der tilføjes en `/shutdown-on-done on|off|status`-kommando, en Stop-hook og en **power-toggle-knap** i panelet (lyser, mens en request står; klik igen for at annullere).

## Brug

- Skift til Claude-appen — strimlen dukker op i bundbjælken.
- **Højreklik på prik-grebet** → *Pin new button* → hold over *Only this chat* eller *Global* → klik en kommando.
- **Venstreklik** på en knap for at skrive dens kommando; globale knapper trykker også Enter, chat-knapper lader dig se teksten først.
- **Højreklik på en knap** → omdøb, redigér tekst, vælg ikon, on/off-tilstand, flyt eller fjern.
- **Position** og **Sprog** ligger i samme grebs-menu. Skift til dansk under *Language → Dansk*.

## Fejlsøgning

- **Strimlen sidder skævt eller per-chat/split-knapper driller efter en app-opdatering** → appens UI er ændret. Se `%LOCALAPPDATA%\claude-buttons.log` og juster de app-afhængige felter i `buttons.json` (`uiaPaneMatch`, `uiaPaneName`, `uiaSidebarName`, `zoneTop`, `zoneBottom`, `fallbackRow`, `stripGap`, `reservedW`). Bed evt. Claude om at "probe appens UIA-træ og opdatere felterne".
- **App ikke på engelsk?** Accessibility-navne som `Primary pane`/`Sidebar` kan være oversatte — sæt `uiaPaneMatch`/`uiaSidebarName` til de lokaliserede navne.
- **`/pin` ukendt kommando eller gør ingenting** → genstart Claude-appen; skillen skriver til filen nævnt i `%USERPROFILE%\.claude\claude-buttons-path.txt`.
- **Intet vises** → strimlen vises kun, når Claude-vinduet er i forgrunden.

*(Fuld config-reference: se [README.md](README.md).)*

## Afinstallation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## Licens

MIT — se [LICENSE](LICENSE).
