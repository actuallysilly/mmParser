"""Pass 6c: fine-tune a small causal LM on the TRAIN days only.

    .venv python p6_ft.py <base model> <out name> [--epochs 3] [--lr 1e-4]

Format: each day is its messages in order, one per line, so the model also
learns from the messages before the current one. Days are joined by EOS and cut
into 256-token blocks. Plain PyTorch loop (no Trainer), bf16, AdamW, cosine.
Saves the epoch with the lowest loss on the test days to userdata/corpus/models/.
"""
import argparse
import math
import random
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from bench_common import split
from rcommon import CORPUS

ap = argparse.ArgumentParser()
ap.add_argument("base")
ap.add_argument("name")
ap.add_argument("--epochs", type=int, default=3)
ap.add_argument("--lr", type=float, default=1e-4)
ap.add_argument("--bs", type=int, default=16)
ap.add_argument("--block", type=int, default=256)
ap.add_argument("--lora", type=int, default=0, help="LoRA rank; 0 = full fine-tune")
args = ap.parse_args()

train, test = split()
tok = AutoTokenizer.from_pretrained(args.base)
eos = tok.eos_token_id


def blocks(msgs):
    by_day = {}
    for m in msgs:
        by_day.setdefault(m.day, []).append(m.text)
    ids = []
    for day in sorted(by_day):
        ids += tok("\n" + "\n".join(by_day[day]) + "\n", add_special_tokens=False).input_ids + [eos]
    B = args.block
    return [ids[i:i + B] for i in range(0, len(ids) - B + 1, B)], len(ids)


tr_blocks, tr_tokens = blocks(train)
te_blocks, te_tokens = blocks(test)
print(f"train {tr_tokens} tokens -> {len(tr_blocks)} blocks; test {te_tokens} tokens")

lm = AutoModelForCausalLM.from_pretrained(args.base, dtype=torch.bfloat16).cuda()
if args.lora:
    from peft import LoraConfig, get_peft_model
    lm = get_peft_model(lm, LoraConfig(r=args.lora, lora_alpha=2 * args.lora, lora_dropout=0.05,
                                       target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                                                       "gate_proj", "up_proj", "down_proj"]))
    lm.print_trainable_parameters()
    lm.gradient_checkpointing_enable()
    lm.enable_input_require_grads()
elif sum(p.numel() for p in lm.parameters()) > 4e8:
    lm.gradient_checkpointing_enable()
opt = torch.optim.AdamW([p for p in lm.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.01, betas=(0.9, 0.95))
steps = args.epochs * math.ceil(len(tr_blocks) / args.bs)
warm = max(20, steps // 20)
sched = torch.optim.lr_scheduler.LambdaLR(
    opt, lambda s: min(1, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(1, s / steps))))


@torch.no_grad()
def eval_loss():
    lm.eval()
    tot = n = 0
    for i in range(0, len(te_blocks), 32):
        x = torch.tensor(te_blocks[i:i + 32]).cuda()
        out = lm(input_ids=x, labels=x)
        tot += out.loss.item() * len(x)
        n += len(x)
    lm.train()
    return tot / n


out_dir = CORPUS / "models" / args.name
best = eval_loss()
print(f"epoch 0 test loss {best:.3f} (ppl {math.exp(best):.1f})")
lm.train()
t0 = time.time()
for ep in range(1, args.epochs + 1):
    random.Random(ep).shuffle(tr_blocks)
    for i in range(0, len(tr_blocks), args.bs):
        x = torch.tensor(tr_blocks[i:i + args.bs]).cuda()
        loss = lm(input_ids=x, labels=x).loss
        loss.backward()
        torch.nn.utils.clip_grad_norm_(lm.parameters(), 1.0)
        opt.step()
        sched.step()
        opt.zero_grad(set_to_none=True)
    tl = eval_loss()
    print(f"epoch {ep} test loss {tl:.3f} (ppl {math.exp(tl):.1f})  {time.time() - t0:.0f}s", flush=True)
    if tl < best:
        best = tl
        lm.save_pretrained(out_dir / "adapter" if args.lora else out_dir)
        tok.save_pretrained(out_dir)
        print(f"  saved -> {out_dir}")
print(f"best test loss {best:.3f}  train time {time.time() - t0:.0f}s")
if args.lora:
    # reload the best adapter and merge it, so the benchmark loads a plain model
    from peft import PeftModel
    base = AutoModelForCausalLM.from_pretrained(args.base, dtype=torch.bfloat16)
    PeftModel.from_pretrained(base, out_dir / "adapter").merge_and_unload().save_pretrained(out_dir)
    tok.save_pretrained(out_dir)
    print(f"merged -> {out_dir}")
