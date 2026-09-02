# tools/packaging — building the installer you **send to someone else**

This folder produces `MMA-Setup.exe`: one file you can hand to somebody who has never seen
GitHub, does not have the repo, and should not have to.

**Entry point: `build.bat`.** Needs Inno Setup 6
(`winget install --id JRSoftware.InnoSetup`). Output lands in `dist\`, which is gitignored —
the exe is a build artifact and is never committed.

| file | what it is |
|---|---|
| `MMA.iss` | The Inno Setup script. The exe it builds is a **bootstrapper**: it carries no copy of MMA, it downloads the current main branch while the wizard runs, so it never goes stale on the shelf. It also asks Easy or Advanced, offers the Python extras, and doubles as the uninstaller — which is why there is no second file to send alongside it. |
| `WELCOME.txt` | The plain-text message shown before installing. Edit it freely; no need to touch the .iss. |
| `build.bat` | Compiles it. Deletes the previous build first, so a failed compile leaves an empty `dist\` rather than a stale exe that looks fresh. |

The version comes from `version.txt`, not from a number typed in the .iss — a version that
lives only in an installer script is a version nobody remembers to bump.

Python packages are **not** named in `MMA.iss`. The wizard runs
`pip install -r requirements.txt` against the tree it has just installed. It used to carry
its own list, and that list had drifted: it installed no `pynput`, so typelog and autoword
silently refused to start on every machine set up from the exe.

> **Not to be confused with [`tools/install/`](../install/)**, which installs MMA on a
> machine that already has the repo. That folder installs; this one packages.
