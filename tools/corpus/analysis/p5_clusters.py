"""Pass 5b: meaning clusters. Run with the autoword venv (GPU):

    src\\services\\autoword\\.venv\\Scripts\\python.exe p5_clusters.py

Embeds every clean message of 3+ words, k-means into K clusters, and writes a
sample of each cluster for reading (clusters_sample.txt) plus the assignments.
"""
import collections
import json
import random

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.cluster import KMeans

from rcommon import OUT, load_repaired, wtoks

K = 48
M = [m for m in load_repaired() if not m.dirty and len(wtoks(m.text)) >= 3]
texts = [m.text for m in M]
model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2", device="cuda")
E = model.encode(texts, batch_size=512, normalize_embeddings=True, show_progress_bar=False)
np.save(OUT / "embeddings_minilm.npy", E)

km = KMeans(n_clusters=K, n_init=4, random_state=0).fit(E)
lab = km.labels_
dist = np.linalg.norm(E - km.cluster_centers_[lab], axis=1)
sizes = collections.Counter(lab.tolist())

random.seed(1)
with open(OUT / "clusters_sample.txt", "w", encoding="utf-8") as fh:
    for c, n in sizes.most_common():
        idx = np.where(lab == c)[0]
        central = idx[np.argsort(dist[idx])][:6]
        rnd = random.sample(list(idx), min(8, len(idx)))
        fh.write(f"\n=== cluster {c}  n={n}  ({n / len(M):.1%})\n")
        for i in list(central) + rnd:
            fh.write(f"  {'*' if i in central else ' '} {texts[i][:120]}\n")
json.dump({"K": K, "n": len(M), "sizes": {int(k): v for k, v in sizes.items()},
           "labels": lab.tolist()}, open(OUT / "clusters.json", "w"))
print("embedded", len(M), "clusters", K)
