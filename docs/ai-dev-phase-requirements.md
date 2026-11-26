# AI development phase — requirements

Written 2026-10-27.

## What this phase is

We are **limit testing**, not shipping. The goal is to find out how good the
local model has to be for the chatting work (see `docs/chatting-process.md`)
and what hardware that takes, **before** spending money on GPUs.

Speed is not a goal here. A slow model that answers the quality question is a
valid test. Production speed rules (`[AI] TimeoutMs`, "must fit VRAM") apply
later, once the model size is decided.

## Current hardware

| Part | Amount | Usable for a model |
|---|---|---|
| GPU | RTX 5070 Ti, 16 GB VRAM | ~12 GB free with the desktop running; ~14 GB with browsers/OBS closed |
| System RAM | 32 GB | ~24–26 GB for spilled layers |
| **Hard ceiling** | | **~40 GB of model weights**; bigger will not load |

## Capacity tiers on this machine

Speeds are estimates until requirement R2 measures them.

| Tier | Fits | Example models | Expected speed |
|---|---|---|---|
| 1. Fully on the GPU | up to ~24B | Cydonia 24B / Mistral Small 24B (Q3_K_M–IQ4_XS), Qwen3 14B Q4, gpt-oss-20b | 30–60+ tok/s |
| 2. Mixture-of-experts, offloaded | 30B MoE | Qwen3-30B-A3B Q4 (~18 GB) | ~15–30 tok/s |
| 3. Dense, partly offloaded | 32B Q4 (~20 GB) | Qwen 32B-class | ~5–10 tok/s |
| 4. Ceiling | 70B at IQ2_M–IQ3_XXS (~24–28 GB) | Llama 3.3 70B and its roleplay tunes | ~1–3 tok/s, 1–3 min per reply |
| — Will not load | 70B Q4 (~42 GB), 100B+ | GLM-4.5-Air, gpt-oss-120b, Llama 4 Scout | — |

The baseline is what runs today: Rocinante 12B and Mistral Nemo 12B.

## Requirements

**R1 — Same test for every model.** Every candidate runs through
`src/services/llm/bakeoff.py` with the same prompts and fan histories, so
quality is compared like for like with Rocinante 12B.

**R2 — Measure, don't guess.** For each run, record:
- the model, quantization and file size
- the GPU/CPU split (`ollama ps`)
- tokens per second for generation and for prompt processing
- time to a full reply
- the bakeoff quality score, plus Silly's verdict

**R3 — Check the offload penalty first.** Earlier notes recorded spilling past
VRAM as 147× slower. Normal partial offload costs 3–10×, so 147× points to a
configuration problem (context size, `num_gpu`, or the KV cache spilling).
Re-measure before ruling out tiers 3–4.

**R4 — Test order.**
1. Cydonia 24B, fully on the GPU (tier 1)
2. Qwen3-30B-A3B (tier 2)
3. A 32B dense model at Q4 (tier 3)
4. A 70B at IQ3_XXS (tier 4), as a preview of the quality ceiling

**R5 — Rent before buying.** If tier 4 looks clearly better than tier 1, rent
a 48 GB GPU (RunPod/Vast.ai, about $0.50–1 an hour) and run a 70B at Q4 through
the same bakeoff. A low-quantization 70B on this machine understates real 70B
quality, so this rental is the real test.

**R6 — Buying rule.**
- Buy **two RTX 3090s (48 GB)** only if the rented 70B Q4 is clearly better
  than the best 24–30B model for the chatting work. 48 GB runs a 70B Q4
  fully on the GPUs.
- A **single 3090 (24 GB)** isn't worth it for this decision. It adds 32B fully
  on the GPU, and the current card can already test 32B with offloading.
- If 24–30B is good enough, buy nothing. Tier 1 or 2 is the production target.

## Exit criteria

This phase ends when there is a recorded answer to: **"What is the smallest
model that is good enough, and does it fit the current card?"** That answer
sets the production model and the hardware plan.
