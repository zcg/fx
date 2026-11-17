import os, re, subprocess

files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()
rows = []
total_hunks = 0
for f in files:
    try:
        text = open(f, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        rows.append((f, -1, -1, -1))
        continue
    hunks = len(re.findall(r"^<{7} ", text, re.M))
    ours = len(re.findall(r"^<{7} ", text, re.M))
    total_hunks += hunks
    lines = text.count("\n")
    rows.append((f, hunks, lines))

rows.sort(key=lambda r: (r[1], r[0]))
print(f"files={len(rows)} total_hunks={total_hunks}")
for f, h, l in rows:
    print(f"{h:3} hunks  {l:6} lines  {f}")