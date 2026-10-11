"""Pass 3: vocabulary and style on the repaired corpus."""
import collections
import json
import re

from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS

from rcommon import OUT, load_repaired, wtoks

M = load_repaired()
W = collections.Counter()
for m in M:
    W.update(wtoks(m.text))
total = sum(W.values())
ranked = W.most_common()


def coverage(p):
    acc = 0
    for i, (_, n) in enumerate(ranked, 1):
        acc += n
        if acc / total >= p:
            return i


res = {"messages": len(M), "word_tokens": total, "vocab": len(W),
       "hapax": sum(1 for n in W.values() if n == 1),
       "coverage_words_needed": {f"{int(p * 100)}%": coverage(p) for p in (.5, .8, .9, .95, .99)},
       "top60": ranked[:60],
       "top_content": [(w, n) for w, n in ranked if w not in ENGLISH_STOP_WORDS and len(w) > 2][:80]}

# emoticons & expressive markers
EMO = collections.Counter()
for m in M:
    for e in re.findall(r"<3+|>\.<|[;:]3|[;:]\(|[;:]\)|xD|XD|:P|;P|\^\^|uwu|owo|:D", m.text):
        EMO[e] += 1
res["emoticons"] = EMO.most_common(20)
res["lines_with_emoticon"] = sum(1 for m in M if re.search(r"<3|>\.<|[;:]3|[;:][()]|xD|uwu", m.text, re.I)) / len(M)

starts_cap = sum(1 for m in M if m.text[:1].isupper())
res["starts_capital"] = starts_cap / len(M)
caps_words = sum(1 for m in M for w in re.findall(r"\b[A-Z]{2,}\b", m.text) if w not in ("I", "OK", "POV", "JOI", "PPV", "DM", "DMS", "TOS", "GF", "BF", "US", "UK"))
res["allcaps_words_per_1000"] = caps_words / total * 1000
res["lines_with_elongation"] = sum(1 for m in M if re.search(r"([A-Za-z])\1(?=\b|[^A-Za-z])", m.text) and re.search(r"\b\w*([a-z])\1\b", m.text.lower())) / len(M)

END = collections.Counter()
for m in M:
    t = m.text.rstrip()
    e = re.search(r"(<3+|>\.<|[;:]3|[;:][()]|\.\.\.|\.\.|!!+|!|\?+|\.|[A-Za-z0-9])$", t)
    END["word (no punct)" if e and e[1][-1].isalnum() else (e[1] if e else "other")] += 1
res["line_endings"] = END.most_common(12)

FIRST = collections.Counter()
FIRST2 = collections.Counter()
for m in M:
    w = wtoks(m.text)
    if w:
        FIRST[w[0]] += 1
    if len(w) >= 2:
        FIRST2[" ".join(w[:2])] += 1
res["first_word"] = FIRST.most_common(40)
res["first_two"] = FIRST2.most_common(40)
res["first_word_top20_share"] = sum(n for _, n in FIRST.most_common(20)) / len(M)

# greetings with a fan's name
GREET = re.compile(r"^(?:hey+|hi+|hello+|heyy+|hii+|oh hey+|omg|hey there)\s+([A-Z][a-z]+)\b", re.I)
names = collections.Counter()
greet_lines = 0
for m in M:
    g = GREET.match(m.text)
    if g:
        greet_lines += 1
        names[g[1]] += 1
res["greeting_with_name_lines"] = greet_lines
res["greeting_distinct_names"] = len(names)
res["greeting_top_names"] = names.most_common(15)
res["lines_per_day_by_day"] = collections.Counter(m.day for m in M)

(OUT / "p3_style.json").write_text(json.dumps(res, indent=1))
for k, v in res.items():
    if k in ("top60", "top_content", "first_word", "first_two", "lines_per_day_by_day"):
        print(k, v[:40] if isinstance(v, list) else "")
    else:
        print(k, v)
