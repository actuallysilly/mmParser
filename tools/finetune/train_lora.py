"""
tools/finetune/train_lora.py — QLoRA on the co-chatter set (build_sft.py).

The base is loaded in 4-bit (nf4) and a LoRA (rank 16, attention + MLP) is
trained on Silly's bursts only: the prompt tokens are masked, so it learns what
she writes, not to repeat the prompt.

The text is laid out in EXACTLY the template Ollama uses for that model, so the
adapter sees at training what it will see at run time:

    chatml   rocinante:latest  <|im_start|>system ... <|im_end|> ... assistant
    mistral  mistral-nemo:12b  [INST]{system}\\n\\n{user}[/INST] {assistant}</s>

Writes to --out: adapter_model.safetensors + adapter_config.json (what an
Ollama ADAPTER line loads), train_log.jsonl, report.md (eval loss before and
after, and the same 12 held-out chats answered by base and tuned).

    train_lora.py --base E:/MMA-train/base/rocinante-12b-v1.1 --format chatml --out ...
"""
from __future__ import annotations

import argparse
import json
import math
import random
import time
from pathlib import Path

import torch
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "userdata" / "corpus" / "sft" / "co_v1"


def layout(fmt: str, system: str, user: str) -> tuple[str, str]:
    """(prompt text, end-of-turn text) in the model's Ollama template."""
    if fmt == "chatml":
        return (f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n"
                f"<|im_start|>assistant\n", "<|im_end|>")
    return f"[INST]{system}\n\n{user}[/INST] ", ""        # mistral: </s> = eos, added as an id


def encode(tok, fmt, system, ex, max_len):
    prompt, end = layout(fmt, system, ex["user"])
    p = tok(prompt, add_special_tokens=False)["input_ids"]
    a = tok(ex["assistant"] + end, add_special_tokens=False)["input_ids"]
    if fmt == "mistral":
        a = a + [tok.eos_token_id]
    ids = ([tok.bos_token_id] if tok.bos_token_id is not None else []) + p + a
    labels = [-100] * (len(ids) - len(a)) + a
    if len(ids) > max_len:
        return None
    return {"input_ids": ids, "labels": labels}


def batches(rows, bs):
    for i in range(0, len(rows), bs):
        chunk = rows[i:i + bs]
        n = max(len(r["input_ids"]) for r in chunk)
        ids = torch.full((len(chunk), n), 0, dtype=torch.long)
        lab = torch.full((len(chunk), n), -100, dtype=torch.long)
        att = torch.zeros((len(chunk), n), dtype=torch.long)
        for j, r in enumerate(chunk):
            L = len(r["input_ids"])
            ids[j, :L] = torch.tensor(r["input_ids"])
            lab[j, :L] = torch.tensor(r["labels"])
            att[j, :L] = 1
        yield ids, lab, att


def target_loss(model, ids, lab, att):
    """Loss on her reply only, computing logits ONLY for those positions.

    The reply is the last ~30 tokens of a ~2,000-token example. Asking the
    model for every position's logits builds a 2,000 x 131,072 table (~1.5 GB
    in fp32, plus copies), which pushed a 16 GB card into shared memory and
    made one forward pass take minutes. `logits_to_keep` returns the tail only.
    Batch size 1: the target is the tail of the row."""
    k = int((lab != -100).sum()) + 1
    out = model(input_ids=ids.cuda(), attention_mask=att.cuda(), logits_to_keep=k)
    logits = out.logits[:, :-1, :].float()
    target = lab[:, -(k - 1):].cuda()
    return torch.nn.functional.cross_entropy(logits.reshape(-1, logits.size(-1)), target.reshape(-1)), k - 1


@torch.no_grad()
def eval_loss(model, rows):
    model.eval()
    tot, n = 0.0, 0
    for ids, lab, att in batches(rows, 1):
        loss, k = target_loss(model, ids, lab, att)
        tot += loss.item() * k
        n += k
    model.train()
    return tot / max(n, 1)


@torch.no_grad()
def generate(model, tok, fmt, system, ex):
    prompt, _ = layout(fmt, system, ex["user"])
    ids = tok(prompt, add_special_tokens=False, return_tensors="pt")["input_ids"]
    if tok.bos_token_id is not None:
        ids = torch.cat([torch.tensor([[tok.bos_token_id]]), ids], 1)
    stop = [tok.eos_token_id] + ([tok.convert_tokens_to_ids("<|im_end|>")] if fmt == "chatml" else [])
    stop = [s for s in stop if isinstance(s, int) and s >= 0]
    # Gradient checkpointing switches the KV cache off, so every new token
    # re-read the whole 2,000-token prompt: one sample took over 8 minutes.
    model.eval()
    model.gradient_checkpointing_disable()
    try:
        out = model.generate(ids.cuda(), max_new_tokens=80, do_sample=True, temperature=0.8,
                             top_p=0.95, eos_token_id=stop, pad_token_id=tok.eos_token_id,
                             use_cache=True)
    finally:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.train()
    text = tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True)
    return text.split("<|im_end|>")[0].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--format", choices=("chatml", "mistral"), required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=float, default=2)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=3072)
    ap.add_argument("--samples", type=int, default=12)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    logf = (out / "train_log.jsonl").open("a", encoding="utf-8")

    def log(**kw):
        kw["t"] = round(time.time(), 1)
        logf.write(json.dumps(kw) + "\n")
        logf.flush()
        print(kw, flush=True)

    systems = {"alice": (DATA / "system_alice.txt").read_text(encoding="utf-8"),
               "basic": (DATA / "system_basic.txt").read_text(encoding="utf-8")}
    load = lambda n: [json.loads(l) for l in (DATA / n).read_text(encoding="utf-8").splitlines()]
    train_ex, eval_ex = load("train.jsonl"), load("eval.jsonl")

    tok = AutoTokenizer.from_pretrained(a.base)
    cfg = json.loads((Path(a.base) / "config.json").read_text(encoding="utf-8"))
    kw = {"dtype": torch.bfloat16, "device_map": {"": 0}}
    if "quantization_config" not in cfg:             # full weights: quantize as they load
        kw["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=torch.bfloat16)
    t0 = time.time()
    model = AutoModelForCausalLM.from_pretrained(a.base, **kw)
    log(event="loaded", s=round(time.time() - t0), vram_gb=round(torch.cuda.memory_allocated() / 1e9, 1))

    enc = lambda rows: [r for r in (encode(tok, a.format, systems[e["system_voice"]], e, a.max_len)
                                    for e in rows) if r]
    tr, ev = enc(train_ex), enc(eval_ex)
    lens = sorted(len(r["input_ids"]) for r in tr)
    log(event="data", train=len(tr), eval=len(ev), dropped_long=len(train_ex) - len(tr),
        tokens_median=lens[len(lens) // 2], tokens_max=lens[-1])

    model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model = get_peft_model(model, LoraConfig(
        r=a.rank, lora_alpha=2 * a.rank, lora_dropout=0.05, bias="none", task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]))

    random.seed(3)
    picks = random.sample(eval_ex, min(a.samples, len(eval_ex)))
    with model.disable_adapter():
        base_loss = eval_loss(model, ev)
        log(event="eval", stage="base", loss=round(base_loss, 4), ppl=round(math.exp(base_loss), 2))
        base_gen = [generate(model, tok, a.format, systems[e["system_voice"]], e) for e in picks]

    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr, weight_decay=0.0)
    steps = math.ceil(len(tr) * a.epochs / a.accum)
    warm = max(1, steps // 20)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(s, steps) / steps)))
    model.train()
    step, micro, run = 0, 0, 0.0
    t0 = time.time()
    epoch = 0
    while step < steps:
        random.seed(100 + epoch)
        order = tr[:]
        random.shuffle(order)
        for ids, lab, att in batches(order, 1):
            loss, _ = target_loss(model, ids, lab, att)
            (loss / a.accum).backward()
            run += loss.item()
            micro += 1
            if micro % a.accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step(); sched.step(); opt.zero_grad(set_to_none=True)
                step += 1
                if step % 5 == 0 or step == steps:
                    el = time.time() - t0
                    log(event="step", step=step, of=steps, loss=round(run / (5 * a.accum), 4),
                        lr=round(sched.get_last_lr()[0], 7), min=round(el / 60, 1),
                        eta_min=round(el / step * (steps - step) / 60, 1),
                        vram_gb=round(torch.cuda.max_memory_allocated() / 1e9, 1))
                    run = 0.0
                if step >= steps:
                    break
        epoch += 1
        model.save_pretrained(out)                   # adapter only, every epoch
        log(event="epoch", epoch=epoch, eval_loss=round(eval_loss(model, ev), 4))

    tuned_loss = eval_loss(model, ev)
    log(event="eval", stage="tuned", loss=round(tuned_loss, 4), ppl=round(math.exp(tuned_loss), 2))
    model.save_pretrained(out)
    tuned_gen = [generate(model, tok, a.format, systems[e["system_voice"]], e) for e in picks]

    md = [f"# {out.name}\n", f"Base `{a.base}`, template `{a.format}`, rank {a.rank}, lr {a.lr}, "
          f"{a.epochs} epochs, {len(tr)} train / {len(ev)} eval examples.\n",
          f"| | eval loss | perplexity |\n|---|---|---|\n| base | {base_loss:.3f} | {math.exp(base_loss):.1f} |\n"
          f"| tuned | {tuned_loss:.3f} | {math.exp(tuned_loss):.1f} |\n",
          "Lower is better: how surprised the model is by what Silly really wrote next, on chats it never trained on.\n",
          "## The same held-out chats, base vs tuned (one sample each)\n"]
    for e, b, t in zip(picks, base_gen, tuned_gen):
        chat = e["user"].split("CHAT:\n", 1)[1].replace("\n\nWrite her next texts.", "")
        last = "\n".join(chat.splitlines()[-4:])
        md.append(f"---\n```\n{last}\n```\n**Silly sent:**\n```\n{e['assistant']}\n```\n"
                  f"**base:**\n```\n{b}\n```\n**tuned:**\n```\n{t}\n```\n")
    (out / "report.md").write_text("\n".join(md), encoding="utf-8")
    log(event="done")


if __name__ == "__main__":
    main()
