# tools/install — putting MMA on **this** machine

You already have the repo. This installs what MMA needs and configures MMA for whatever
you chose to skip.

**Entry point: [`install.bat`](../../install.bat) in the repo root.** Double-click it.
That is the only thing anybody needs to run; everything here is called by it.

| file | what it is |
|---|---|
| `install.ps1` | The installer. Finds or winget-installs AutoHotkey v2, optionally sets up Python, then writes `AutomationListener=0` / `Pinger=0` into `userdata\mass_gui.cfg` if you declined — without which a Python-less machine gets a WScript error box on every single launch. |
| `createShortcut.bat` | The desktop shortcut on its own, for someone who installed AutoHotkey by hand and wants nothing else touched. It calls `install.ps1 -ShortcutOnly`; the shortcut is written in one place only. |

```
install.bat                 interactive
install.bat -WithPython     assume yes to the optional Python features
install.bat -NoPython       assume no
```

Python packages are **not** named in `install.ps1`. It runs
`pip install -r requirements.txt` against the repo root, which pulls in each service's own
`requirements.txt` — see the header of [`requirements.txt`](../../requirements.txt) for the
drift that made that necessary.

> **Not to be confused with [`tools/packaging/`](../packaging/)**, which builds the
> `MMA-Setup.exe` you send to someone who does *not* have the repo. This folder installs;
> that one packages.
