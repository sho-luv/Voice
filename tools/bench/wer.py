#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""wer.py — word error rate per test set from `Voice --bench` output.

Usage:
  Voice --bench dir ... > hyp.tsv
  tools/bench/wer.py refs.json hyp.tsv [more.tsv ...]

refs.json maps an utterance id to its reference text. Hypothesis lines are "set/id<TAB>text".
Text is lowercased and stripped of punctuation before scoring; a few spelled-out forms are
folded so "mister"/"mr" and "ok"/"okay" don't count as errors.
"""
import json, re, sys, collections

FOLD = {"mr": "mister", "mrs": "missus", "dr": "doctor", "st": "saint", "ok": "okay", "&": "and"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()

def number(n):
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10 - 2] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    return str(n)

def norm(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"\b(\d{1,2})\b", lambda m: number(int(m.group(1))), text)
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    words = [FOLD.get(w.strip("'"), w.strip("'")) for w in text.split()]
    return [w for w in words if w]

def errors(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1]

def main():
    refs = json.load(open(sys.argv[1]))
    for path in sys.argv[2:]:
        sets = collections.OrderedDict()
        for line in open(path):
            if "\t" not in line: continue
            key, text = line.rstrip("\n").split("\t", 1)
            name, uid = key.split("/", 1)
            if uid not in refs: continue
            r, h = norm(refs[uid]), norm(text)
            e, n = sets.get(name, (0, 0))
            sets[name] = (e + errors(r, h), n + len(r))
        print(path)
        for name, (e, n) in sets.items():
            print(f"  {name:14s} WER {100 * e / max(n, 1):6.2f}%   ({e}/{n} words)")

if __name__ == "__main__":
    main()
