r"""
autoword — is the language-model environment working?

Run it with the venv's Python, not the global one:

    .venv\Scripts\python.exe lm_check.py [model]

Loads a small model onto the GPU, ranks a handful of next words against a
sentence, and times it. The default model is SmolLM2-135M; it is downloaded to
the Hugging Face cache on first run. Nothing here is used by the service.
"""
from __future__ import annotations

import sys
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL = sys.argv[1] if len(sys.argv) > 1 else "HuggingFaceTB/SmolLM2-135M"
SENTENCE = "i was thinking about you all day and i really want to"
CANDIDATES = ["see", "know", "talk", "show", "send", "say", "the", "sleep"]


def rerank(tok, lm, sentence: str, words: list[str]) -> list[tuple[str, float]]:
    """Sum of each word's token log-probs after `sentence`, in one batch."""
    ctx = tok(sentence, return_tensors="pt").input_ids[0]
    seqs = [torch.cat([ctx, tok(" " + w, return_tensors="pt").input_ids[0]]) for w in words]
    width = max(len(s) for s in seqs)
    pad = tok.pad_token_id if tok.pad_token_id is not None else 0
    ids = torch.full((len(seqs), width), pad, dtype=torch.long)
    mask = torch.zeros_like(ids)
    for i, s in enumerate(seqs):
        ids[i, :len(s)] = s
        mask[i, :len(s)] = 1
    ids, mask = ids.to(lm.device), mask.to(lm.device)

    with torch.inference_mode():
        logp = lm(input_ids=ids, attention_mask=mask).logits.float().log_softmax(-1)

    # token t is predicted by the logits at position t-1. Gathered on the GPU and
    # copied back once: an .item() per token is a GPU sync per token, and that
    # loop, not the model, was most of the time.
    picked = logp[:, :-1].gather(-1, ids[:, 1:, None])[..., 0]
    keep = torch.zeros_like(picked)
    for i, s in enumerate(seqs):
        keep[i, len(ctx) - 1:len(s) - 1] = 1
    scores = (picked * keep).sum(-1).tolist()
    return sorted(zip(words, scores), key=lambda ws: -ws[1])


def main() -> int:
    print(f"torch {torch.__version__}  cuda {torch.version.cuda}  available {torch.cuda.is_available()}")
    if not torch.cuda.is_available():
        print("No GPU visible — this is the CPU build of torch, or the driver is too old.")
        return 1
    print(f"device {torch.cuda.get_device_name(0)}")

    t = time.perf_counter()
    tok = AutoTokenizer.from_pretrained(MODEL)
    lm = AutoModelForCausalLM.from_pretrained(MODEL, dtype=torch.float16).cuda().eval()
    print(f"loaded {MODEL} in {time.perf_counter() - t:.1f}s, "
          f"{torch.cuda.memory_allocated() / 2**20:.0f} MB VRAM")

    rerank(tok, lm, SENTENCE, CANDIDATES)          # warm-up: first call compiles kernels
    runs = []
    for _ in range(20):
        t = time.perf_counter()
        ranked = rerank(tok, lm, SENTENCE, CANDIDATES)
        torch.cuda.synchronize()
        runs.append((time.perf_counter() - t) * 1000)
    runs.sort()

    print(f'\n"{SENTENCE} ..."')
    for word, score in ranked:
        print(f"  {word:<8} {score:7.2f}")
    print(f"\nrerank {len(CANDIDATES)} words: p50 {runs[len(runs) // 2]:.1f} ms, worst {runs[-1]:.1f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
