#!/usr/bin/env python3
"""Joins the app's hitch log with the UI test's PHASE lines: hitches per phase."""
import re, sys
log, test = sys.argv[1], sys.argv[2]
hitches = [tuple(map(float, l.split())) for l in open(log) if l.strip()]
for m in re.finditer(r"PHASE (\S+) ([\d.]+) ([\d.]+)", open(test, errors="ignore").read()):
    name, a, b = m.group(1), float(m.group(2)), float(m.group(3))
    hs = [d for t, d in hitches if a <= t <= b]
    big = [d for d in hs if d >= 50]
    print(f"{name:18s} {b-a:5.1f}s  hitches={len(hs):3d}  total={sum(hs):7.0f}ms  ratio={sum(hs)/(b-a):6.1f}ms/s  worst={max(hs, default=0):6.0f}ms  ≥50ms:{len(big)}")
