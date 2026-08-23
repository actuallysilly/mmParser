"""
llm/client.py — the one place MMA talks to Ollama.

Thin on purpose. Everything that decides *what* to ask lives in the feature
modules (draft.py and whatever follows); this only knows how to ask, how long to
wait, and how to say "the model is not there" without taking the caller down.

────────────────────────────────────────────────────────────────────────────────
WHY THE MODEL CHOICE IS A SETTING AND NOT A CONSTANT
────────────────────────────────────────────────────────────────────────────────
The size of the model is the single biggest thing about whether any of this is
usable, and it is decided by how much of it fits in the GPU. Measured on this
machine (RTX 5070 Ti, 16GB):

    qwen3.6:latest    23 GB   41%/59% CPU/GPU     0.7 tok/s   20.7s to load
    mistral-nemo:12b  7.5 GB  100% GPU          102.7 tok/s    2.2s to load

Same machine, same prompt, 147x apart. Everything above ~14GB spills onto the CPU
and stops being interactive at all — a one-sentence reply took 82 seconds on the
23GB model. So `Model` is a setting you will want to change when you change
cards, and the failure it protects against is not subtle.

`KeepAlive` matters nearly as much in practice. Ollama unloads an idle model
after 5 minutes by default, and reloading is the 2.2s above — which lands on
whichever message you happened to send after a coffee. Holding it resident costs
7.5GB of VRAM and nothing else.

────────────────────────────────────────────────────────────────────────────────
IT NEVER RAISES AT THE CALLER
────────────────────────────────────────────────────────────────────────────────
`chat()` returns (text, error). A drafter that throws when Ollama is not running
is a hotkey that throws while you are working, so the failure is a value here.
Nothing in MMA should ever be *blocked* by the AI being unavailable.
"""
from __future__ import annotations

import configparser
import json
import urllib.error
import urllib.request
from pathlib import Path

# userdata\ is where every MMA setting the machine owns lives, and it is
# gitignored — same place autoword.ini and the typelog corpus sit.
MMA_ROOT = Path(__file__).resolve().parents[3]
USERDATA = MMA_ROOT / "userdata"
INI = USERDATA / "llm.ini"

DEFAULT_INI = """\
; MMA — local AI (Ollama). Changes apply the next time a feature runs.
;
; Nothing here reaches the internet: Ollama serves on localhost and the model
; runs on your GPU. That is the whole point of it being local.

[Ollama]
; Where Ollama listens. The default is its own default.
Host = http://127.0.0.1:11434

; WHICH MODEL. This is the setting that decides whether any of this is usable.
; It must fit in your GPU with room for context, or it silently spills onto the
; CPU and gets ~100x slower. Measured here on a 16GB card:
;     mistral-nemo:12b   7.5 GB   100% GPU    102 tok/s     <- usable
;     qwen3.6:latest      23 GB   41% on CPU  0.7 tok/s     <- not
; Check yours with:  ollama ps
Model = mistral-nemo:12b

; How long Ollama holds the model in VRAM after a request. Shorter means the
; next request after a gap pays the load time (~2s) again. "-1" holds it for
; ever, "0" unloads immediately.
KeepAlive = 30m

; Give up after this long. A local model answers in well under a second when it
; is warm; anything near this number means it is loading or on the CPU.
TimeoutMs = 30000

[Draft]
; How many alternative replies to offer.
Count = 3

; Higher is more varied and less predictable. Below ~0.7 the replies start
; repeating each other, which defeats offering three.
Temperature = 0.9

; Cap on reply length, in tokens. A chat reply is short; this is a guard against
; the model writing an essay, not a target.
MaxTokens = 80

; Who she is, in your words. This is the highest-leverage line in the file —
; edit it until the replies sound like the model you are writing as.
Persona = a flirty, playful adult creator talking to a paying fan
"""


def _cfg() -> configparser.ConfigParser:
    """The ini, written with commented defaults the first time it is needed."""
    if not INI.exists():
        USERDATA.mkdir(parents=True, exist_ok=True)
        INI.write_text(DEFAULT_INI, encoding="utf-8")
    cp = configparser.ConfigParser()
    # Persona and friends are prose and may contain a colon or a percent sign;
    # neither should be read as ini syntax.
    cp.read(INI, encoding="utf-8")
    return cp


def get(section: str, key: str, fallback: str = "") -> str:
    return _cfg().get(section, key, fallback=fallback, raw=True).strip()


def get_int(section: str, key: str, fallback: int) -> int:
    try:
        return int(float(get(section, key, str(fallback))))
    except ValueError:
        return fallback


def get_float(section: str, key: str, fallback: float) -> float:
    try:
        return float(get(section, key, str(fallback)))
    except ValueError:
        return fallback


def host() -> str:
    return get("Ollama", "Host", "http://127.0.0.1:11434").rstrip("/")


def model() -> str:
    return get("Ollama", "Model", "mistral-nemo:12b")


def _post(path: str, payload: dict, timeout: float):
    req = urllib.request.Request(host() + path, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def reachable() -> tuple[bool, str]:
    """Is Ollama up, and is the configured model actually pulled?

    Both halves matter and they fail differently: no server is "start Ollama",
    a missing model is "ollama pull X". Reporting one as the other sends you
    looking in the wrong place.
    """
    try:
        req = urllib.request.Request(host() + "/api/tags")
        tags = json.loads(urllib.request.urlopen(req, timeout=3).read())
    except Exception as e:
        return False, f"Ollama is not answering on {host()} ({e.__class__.__name__})"
    names = {m.get("name", "") for m in tags.get("models", [])}
    want = model()
    if want not in names and f"{want}:latest" not in names:
        have = ", ".join(sorted(names)) or "none"
        return False, f"model {want!r} is not pulled (installed: {have})"
    return True, f"{want} ready"


def chat(messages: list[dict], *, temperature: float = 0.8,
         max_tokens: int = 120) -> tuple[str, str]:
    """Ask the model. Returns (text, error) — exactly one of them is non-empty.

    Never raises. A hotkey that throws because a background service is down is
    worse than one that says so.
    """
    timeout = get_int("Ollama", "TimeoutMs", 30000) / 1000.0
    payload = {
        "model": model(),
        "messages": messages,
        "stream": False,
        "keep_alive": get("Ollama", "KeepAlive", "30m"),
        "options": {"temperature": temperature, "num_predict": max_tokens},
    }
    try:
        r = _post("/api/chat", payload, timeout)
    except urllib.error.URLError as e:
        ok, why = reachable()
        return "", why if not ok else f"request failed: {e}"
    except Exception as e:
        return "", f"request failed: {e.__class__.__name__}: {e}"
    text = (r.get("message") or {}).get("content", "").strip()
    if not text:
        return "", "the model returned nothing"
    return text, ""


def warm() -> str:
    """Load the model now, so the first real request does not pay for it."""
    ok, why = reachable()
    if not ok:
        return why
    _text, err = chat([{"role": "user", "content": "hi"}], max_tokens=1)
    return err or f"{model()} warm"


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print(f"ini   : {INI}")
    print(f"host  : {host()}")
    print(f"model : {model()}")
    ok, why = reachable()
    print(f"status: {'OK' if ok else 'DOWN'} — {why}")
