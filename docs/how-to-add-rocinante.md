# How to add Rocinante (and train it on your corpus)

Written 2026-10-11, to pick up the next day.

**Why:** the suggestion key (Ctrl+Alt+D) writes bad lines because its model,
`mistral-nemo:12b`, is a general chatbot that has never seen you write. Rocinante
is a roleplay fine-tune of the same Nemo 12B base: same size, same speed, better
writing. On top of that we train a small add-on (a **LoRA**) on your corpus so it
writes like *you*.

**The rule that decides everything:** the model has to fit in the 16 GB card.
Anything bigger spills onto the CPU and gets ~100× slower (`qwen3.6`: 82 s for one
line). Check with `ollama ps`: the PROCESSOR column must say `100% GPU`.

**What we will most likely build with it: the rewording tool** (Part 0). The
model work below is what makes it good; the tool itself is small.

---

## Part 0 — The rewording tool (the likely first build)

**What it does:** takes a line you *already have*, usually the mass follow-up you
are about to send, and rewrites it to fit what the fan just said, in your voice.
The mass supplies the idea and the escalation; the fan's message supplies the
words to mirror. This is tier 2 ("sexting with input") done the safe way: the
model edits your text instead of inventing from nothing, which is why it can
work even before training.

Not to be confused with autoword's **Ctrl+Tab reword**, which swaps one word
for a synonym from your own group file. This works on the whole message.

### How it works (reuses what is already built)

```
the line in the box ──┐  cut it, exactly like the grammar fixer (Ctrl+X: the
                      │  selection, or the whole box)
the chat on screen ───┤  from the chat reader (userdata\chat_now.json), checked
                      │  against a fresh capture so it is never the previous fan
optional direction ───┤  only if a prompt step is added (see below)
                      ▼
       local model: "rewrite HER line so it answers his last message.
                    keep her idea, her length, her style; use his words"
                      ▼
clipboard, or pasted back in fast mode (same switch as the grammar fixer)
```

| Piece | Reused from |
|---|---|
| cut → process → clipboard / fast paste-back | `src\chat\grammar.ahk` (`_GrammarCut`, `_GrammarGiveBack`, the fast-mode switch) |
| the chat, never stale | `suggest.py` `current_turns()` + `chatreader.pyw` |
| "did it reply instead of rewrite?" guard | `grammar.py` `plausible()` (length check) |
| your voice | the model: stock Rocinante first, the trained LoRA from Part 2 later |

New code is about one `reword.py` (prompt + guard) and one `reword.ahk` (key,
modelled on grammar.ahk), plus a hotkey row (a `^!` key, never a bare F-key).

### Rules the prompt must hold (from what went wrong in the suggester)

- **Keep her line's idea and length.** The suggester's first output was long and
  flowery ("sweet nectar"). A rewrite that grows past ~1.5× the original is
  rejected by the guard, like the grammar fixer's.
- **Mirror his words, do not answer as a chatbot.** "you want me to dictate,
  huh?" is the failure to avoid.
- **Never use the fan's name** (it read "Mike Hunt" off a joke and used it).
- **No new emoji, quotes or `model:` labels**: strip them in code, don't just ask.
- **If he gave nothing to mirror** (ok / mmm / an emoji), hand back the line
  unchanged, or barely touched. That case is the mass's job, not this tool's.

### Decisions for Silly before building

1. **Delivery:** clipboard, or fast paste-back? (The grammar fixer has both, behind
   one Settings switch. Reuse that switch or give this its own?)
2. **Variants:** one rewrite, or 3 to pick from in the suggestion window?
3. **Hook into the mass keys?** e.g. a key that stages the next follow-up already
   reworded, versus a separate key you press on whatever is in the box.
4. **Which key:** `^!w` is taken; `^!t` and `^!y` were free on 2026-10-11.

### How to judge it

The same blind side-by-side as Part 1 step 4: original follow-up vs reworded
(stock Rocinante) vs reworded (trained LoRA), on 10–20 real fan replies. It
earns its key only if the reworded ones read like something you would have
typed.

---

## Part 1 — Add stock Rocinante (≈ 30 min)

### 1. Check for a newer version first

The confirmed release is **v1.1**: [`TheDrummer/Rocinante-12B-v1.1`](https://huggingface.co/TheDrummer/Rocinante-12B-v1.1).
Newer `v2g` GGUF files sit, confusingly, in TheDrummer's `UnslopNemo-12B-v3-GGUF`
repo. Look at https://huggingface.co/TheDrummer and decide which version to use.
**For Part 2 you need the full (non-GGUF) weights of the same version**, and those
are confirmed only for v1.1, so v1.1 is the safe pick.

### 2. Pull it into Ollama

Ollama pulls GGUF files straight from Hugging Face. Q6_K is ~10 GB: good quality,
room to spare on 16 GB.

```
ollama pull hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K
```

If that tag is not found, open the repo's *Files* tab and use the quant name it
actually lists (e.g. `:Q6_K_L`, `:Q5_K_M`).

### 3. Check it is fast

```
ollama run hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K "hi"
ollama ps
```

PROCESSOR must read **100% GPU**. If it shows a CPU share, use a smaller quant
(Q5_K_M, then Q4_K_M).

### 4. Blind comparison against the current model

Open a real chat in Infloww (it can sit behind other windows, just not
minimised), then run each model on the **same screen**:

```
cd src\services\llm
python suggest.py --model mistral-nemo:12b
python suggest.py --model hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K
```

`--model` tries a model without touching `llm.ini`. Do it on 4–5 different chats.

For a fair, repeatable comparison, use **fixed** chats instead of the live screen:
a text file of `her: …` / `fan: …` lines, and both modes:

```
python suggest.py --model <name> --chat-file chat.txt
python suggest.py --model <name> --chat-file chat.txt --mode ppv --tier 1 --content "topless"
```

Each draft that still breaks a rule after the retries is printed with
`!! still: …`. **Count those per model.** On 2026-10-13, `mistral-nemo` passed
filler cleanly but failed most PPV drafts (content ignored, too long).
For a blind read, have Claude shuffle the outputs and hide the model names.

### 5. Switch to it, if it wins

In `userdata\llm.ini`:

```ini
[Ollama]
Model = hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K
```

This switches the **grammar fixer** too, because it reads the same line. Re-test
both grammar keys (Ctrl+Alt+R / Ctrl+Alt+E) after switching. A roleplay model
may be worse at plain proofreading. If it is, the grammar fixer gets its own
`Model` key.

---

## Part 2 — Train it on your corpus (a few hours, mostly unattended)

### What gets trained

A LoRA: a ~100–200 MB add-on on top of Rocinante that shifts its writing toward
yours. Trained with **QLoRA** (the base loaded at 4-bit), which is what makes a 12B
model trainable on a 16 GB card.

| Needed | Have |
|---|---|
| ~12–14 GB VRAM while training | RTX 5070 Ti, 17 GB ✅ |
| ~24 GB disk for the full Rocinante weights | 61 GB free on D: ✅ |
| torch, transformers, peft, accelerate | already in `src\services\autoword\.venv` ✅ |
| bitsandbytes, trl, datasets | **missing**, see step 1 |

### 1. Install the missing libraries

Into autoword's existing training venv. It already has the CUDA build of torch
that matches the driver (cu128); do not let pip replace it.

```
src\services\autoword\.venv\Scripts\pip install bitsandbytes trl datasets
src\services\autoword\.venv\Scripts\python -c "import torch, bitsandbytes; print(torch.__version__, torch.cuda.is_available())"
```

If pip tries to upgrade torch, stop and pin it: `pip install bitsandbytes trl datasets "torch==2.11.0"`.

### 2. Download the full weights (~24 GB)

```
src\services\autoword\.venv\Scripts\huggingface-cli download TheDrummer/Rocinante-12B-v1.1 --local-dir userdata\corpus\models\base\rocinante-12b-v1.1
```

(`userdata\` is gitignored, so none of this lands in git.)

### 3. Build the training set (this is the part that needs care)

Sources:
- `userdata\corpus\repaired\llm_v1.tsv`: ~43k usable lines of yours, in the order you sent them
- `userdata\typelog\messages\*.log`: new messages, tagged with account + conversation
- your masses (`userdata\masses.json`) and hotstring messages: your best scripted sexting

Shape: each example is "your last few lines → your next message", in the
Mistral chat format Rocinante uses.

Known limits, so nobody is surprised:
- **Your side only.** It learns how you *write*, not how you *answer* a fan. Rocinante
  supplies the answering. Recording both sides (the chat reader already sees them)
  fixes this for later training runs. Decide whether to switch that on.
- **Fans are interleaved** in the old logs (61 days, ordered but with no conversation
  tag), so neighbouring lines can belong to different chats. Fine for voice, weaker
  for building one conversation. Only data from 2026-10-11 on has conversation tags.

**Scrub before training.** A trained model can repeat its training text word for
word. Remove fan names, @handles, emails and anything in `userdata\corpus\scrub.txt`
(the password/email that leaked into the raw logs). **Show Silly a sample of the
built set before training.**

**Hold out the newest days** (e.g. everything from 2026-10-01 on) so step 5 judges
it on messages it never saw, the same split autoword's model was measured on.

### 4. Train

QLoRA settings to start from (they still need writing up as a script; this is
what it will contain):

- base: `userdata\corpus\models\base\rocinante-12b-v1.1`, loaded 4-bit (nf4)
- LoRA rank 16, alpha 32, on the attention + MLP projections
- **gradient checkpointing ON.** Without it Windows spills VRAM into system RAM and
  crawls. That is what happened with the 1.5B LoRA: 35 min with no epoch done vs 4 min with it
- 1–2 epochs, sequence length ~512, learning rate ~1e-4
- output: `userdata\corpus\models\rocinante-silly-lora\`

Leave it running. Watch `nvidia-smi`: memory should sit below ~15 GB.

### 5. Load the add-on in Ollama

An Ollama Modelfile can put a LoRA on top of a base model:

```
FROM hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K
ADAPTER D:\Software\Dev\Chatting\MMA\userdata\corpus\models\rocinante-silly-lora
```

```
ollama create rocinante-silly -f Modelfile
```

**To verify on the day:** Ollama says an adapter should match its base model,
and applying one to a *quantized* base may not work. If `ollama create` complains,
or the output looks unchanged, the fallback is: merge the LoRA into the full
weights, convert with llama.cpp's `convert_hf_to_gguf.py`, quantize to Q6_K, and
`ollama create` from that GGUF instead.

### 6. Judge it

Same blind comparison as Part 1 step 4, now with three contestants:

```
python suggest.py --model mistral-nemo:12b
python suggest.py --model hf.co/TheDrummer/Rocinante-12B-v1.1-GGUF:Q6_K
python suggest.py --model rocinante-silly
```

Keep it only if it clearly reads more like you. Then set it as `Model` in
`llm.ini` (see Part 1 step 5 about the grammar fixer).

---

## Open decisions for Silly

1. **v1.1 or a newer Rocinante?** Training needs the full weights of the exact
   version Ollama runs.
2. **Record both sides of conversations?** The chat reader already sees them; saving
   them makes every later training run better at answering, not just at sounding
   like you. It means storing fan messages on disk (in `userdata\`, gitignored).
3. **Masses in the training set?** They are your best sexting but also the most
   repeated text. Too much of them and it will recite them.

## Where things are

| | |
|---|---|
| Suggestion key | `src\chat\suggest.ahk` (Ctrl+Alt+D) |
| Generator | `src\services\llm\suggest.py` (`--model` to try one) |
| Chat reader service | `src\services\llm\chatreader.pyw` → `userdata\chat_now.json` |
| Model setting | `userdata\llm.ini` `[Ollama] Model` |
| Training venv | `src\services\autoword\.venv` |
| Models folder | `userdata\corpus\models\` |
