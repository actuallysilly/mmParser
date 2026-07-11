# MMA — modern GUI

A beautified, modern re-skin of the MMA control panel (`mass_gui.ahk`), intended
to become the real front-end on top of the AHK automation core.

## `mma_app.html` — the port (primary)
A **faithful** rebuild of the `mass_gui.ahk` layout, restyled as a premium dark
desktop app: the Mass 1/2/3 tabs, every field (`!mm`, `f1…f3.7`, `ppv`,
`ppvfu1-3`), the paste block, Parse / Clear / Export / Archive, load & save to
file, Set massNo, and the bottom toolbar (tools, the Ed / M1–M3 × F1–F3 grid,
script toggles, credit). Same controls, same workflow — just modern.

Open it in a browser to preview. It's self-contained and is the **renderer** for
a WebView-based shell (C#/Photino or Electron). Export/Parse are real (verified
positional round-trip); load/save/settings show where the app backend hooks in.

## `mma_command_deck.html` — alternate concept
An exploratory "command deck" dashboard reimagining (funnel-as-node-chain, stat
tiles). Kept as a design reference; **not** the faithful port.

## Status / next step
The chosen desktop framework wraps `mma_app.html` and adds the backend:
- write the parsed fields into `1_mass.ahk` / `2_mass.ahk` / `3_mass.ahk`
- launch / kill the account scripts, watchdog, settings
- read the archive

Uses web fonts (Chakra Petch / Manrope / JetBrains Mono) — needs internet on
first open; degrades to system fonts. Committed to a single dark theme by design.
