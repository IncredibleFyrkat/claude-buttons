# Claude Buttons (dansk)

En slank knap-strimmel, der klistrer sig til **Claude desktop-appens** bundbjælke (Windows) og
skriver slash-kommandoer eller tekst ind i chatten, når du klikker. Pin dine mest brugte
kommandoer som ét-kliks-knapper — globalt eller bundet til en bestemt chat, i bundrækken eller i
en lodret bjælke i hver sin side, grupperet og farvekodet hvis du vil have det sådan.

*(English README — den kanoniske: [README.md](README.md).)*

## Funktioner

- **Pin en hvilken som helst kommando** som pille-knap — enten fra strimlens **⋮-menu** (uden om Claude) eller via `/pin`-skillen.
- **Global eller per-chat.** Per-chat-knapper vises kun, når den chat er på skærmen, og auto-sender aldrig (de indsætter teksten, så du ser den først).
- **Native udseende:** hver strimmel er et gennemsigtigt overlay (per-pixel alpha) uden baggrunds-boks, så pillerne ligner en del af appens egen bjælke.
- **Ikon-knapper** (`"icon": "power"`) i samme størrelse som appens mic-knap — 134 navne fra Windows' indbyggede Segoe Fluent Icons, ingen downloads.
- **On/off-toggle-knapper** (`"toggle": true`) der lyser, mens de er tændt; `stateGlob` kan spejle en filsystem-tilstand, så knappen altid viser sandheden.
- **Lange standard-prompts:** en knaps tekst kan være en hel prompt; lang/multiline tekst indsættes atomisk via clipboard (dit tidligere clipboard gendannes).
- **Composer-forankret docking:** strimlen låser sig til chattens composer i appens accessibility-træ og sidder lige efter appens egne knapper. I split-/stacked-/grid-visning får hver synlig chat sin egen strimmel.
- **Sidebjælker:** flyt knapper til en lodret strimmel i venstre eller højre margen i stedet for bundrækken. ⋮-menuen kan flytte med, og **Flyt til bjælke** tager hele strimlen med sig.
- **Grupper:** fold flere knapper sammen til én knap på bjælken; hold musen over, og medlemmerne folder ud. En gruppe har sit eget ikon og navn, og flyttes som én blok i stedet for at blive spredt.
- **Farver per type:** prompts, kommandoer, grupper og kontakter kan hver få sin farve fra ⋮ → Farver. Typen udledes af knappen, så en nypinnet slash-kommando automatisk får kommandofarven.
- **Knapstørrelse** fra ⋮ → Knapstørrelse, 14–32 px, for hele panelet. Knapperne beholder deres størrelse når vinduet flyttes mellem skærme med forskellig DPI.
- **Knappen kontrollerer før den sender.** Den læser beskedfeltet tilbage gennem accessibility-træet og trykker først Enter, når den kan se at det der landede, kom fra knappen. Kan den ikke bekræfte det — en indsætning der udeblev, en gammel udklipsholder, tekst den ikke selv lagde ind — sender den ingenting, lader feltet være og siger det. Se [CHANGELOG.md](CHANGELOG.md) for hvad den fanger og ikke fanger.
- **To-kliks bekræftelse** på destruktive knapper; **EN/DA** UI; tooltips.
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
- **Klik på ⋮-menuen** (kebab'en yderst til venstre på strimlen) → *Pin new button* → vælg en kommando i undermenuen *Global* eller *Only this chat* (scope vælges i ét klik).
- **Venstreklik** på en knap for at skrive dens kommando; globale knapper trykker også Enter, chat-knapper lader dig se teksten først.
- **Shift-klik** indsætter teksten **uden** at sende, så du kan redigere eller udvide prompten før du selv trykker Enter. (Kun relevant på knapper der ellers sender. Toggles skifter ikke tilstand ved shift-klik: kommandoen er parkeret, ikke kørt.)
- **Højreklik på en knap** → omdøb, redigér tekst, vælg ikon, on/off-tilstand, flyt (*Move left / Move right*) eller fjern.
- **⋮-menuen** rummer også **Farver** (per type), **Knapstørrelse** (10–40 px), **Flyt til bjælke** (knaprækken, venstre eller højre side — hele strimlen flytter med), **Sprog** (English / Dansk), en **Hover tooltips**-kontakt og **Close panel**. Strimlen docker sig selv til composeren — ingen manuel placering.

### Indstillinger i `buttons.json`

Alle kan sættes i filen; de tre første også fra ⋮-menuen.

| Felt | Standard | Betydning |
|---|---|---|
| `btnSize` | `21` | Knapstørrelse i logiske px, 10–40, for hele panelet. Skalerer med skærmen. |
| `colors` | `{}` | Farve per type: `prompt`, `command`, `group`, `toggle`. |
| `kebabBar` | `"row"` | Hvilken bjælke ⋮-håndtaget sidder på: `row`, `left` eller `right`. |
| `bar` (per knap) | `row` | Hvilken bjælke knappen ligger på: `row`, `left` eller `right`. |
| `group` (per knap) | — | Gruppenavn. Grupperede knapper folder sammen til én knap med en udfoldning. Matches **uden** hensyn til store/små bogstaver, fordi navnet er en JSON-nøgle og PowerShells JSON-læser afviser en fil med nøgler der kun adskiller sig i versaltype. |
| `groups` | `{}` | Gruppedefinitioner: `{ "ops": { "icon": "settings", "label": "Drift" } }`. Ryddes automatisk når sidste medlem forlader gruppen. |
| `sideNudge` | `0` | Skubber en **højre** sidebjælke længere væk fra chatten, i logiske px. Nødvendig fordi chattens synlige kant ikke findes i accessibility-træet — alt der *kan* måles (beskedfeltet, knaprækken, ruden) ligger inde i den afrundede boks, så de sidste par pixels kan ikke udledes. Venstre side skal ikke korrigeres og påvirkes ikke. |
| `sideNudgeY` | `0` | Samme, lodret: negativ løfter en højre bjælke, positiv sænker den. |

## Fejlsøgning

- **Strimlen sidder skævt eller forsvinder efter en app-opdatering** → appens UI er ændret. Se `%LOCALAPPDATA%\claude-buttons.log` og juster de app-afhængige felter i `buttons.json`. **Start med `uiaComposerName`** (standard `"Prompt"`): strimlen docker ved at matche composerens accessibility-navn, så en omdøbning dér er den mest sandsynlige årsag og skjuler alle strimler. Derefter `uiaPaneMatch` (split-/grid-paneler) og geometri-værdierne `zoneTop`, `zoneBottom`, `fallbackRow`, `stripGap`, `vNudge`, `reservedW`. Bed evt. Claude om at "probe appens UIA-træ og opdatere felterne".
- **App ikke på engelsk?** Accessibility-navne som `Prompt` og `… pane` kan være oversatte — sæt `uiaComposerName` og `uiaPaneMatch` til de lokaliserede navne.
- **`/pin` ukendt kommando eller gør ingenting** → genstart Claude-appen; skillen skriver til filen nævnt i `%USERPROFILE%\.claude\claude-buttons-path.txt`.
- **Intet vises** → strimlen vises kun, når Claude-vinduet er i forgrunden.

*(Fuld config-reference: se [README.md](README.md).)*

## Afinstallation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## Licens

MIT — se [LICENSE](LICENSE).
