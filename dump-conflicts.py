import re, subprocess

files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()

CTX = 6

def ctx_lines(lines, start, end):
    lo = max(0, start - CTX)
    hi = min(len(lines), end + CTX)
    return lo, hi

out = []
for f in files:
    try:
        text = open(f, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        out.append(f"##### {f}: UNREADABLE")
        continue
    lines = text.split("\n")
    marks = [(i, l) for i, l in enumerate(lines) if l.startswith("<<<<<<< ") or l.startswith(">>>>>>> ")]
    # pair them
    hunks = []
    i = 0
    while i < len(marks) - 1:
        a = marks[i]
        b = marks[i + 1]
        if a[1].startswith("<<<<<<< ") and b[1].startswith(">>>>>>> "):
            hunks.append((a[0], b[0], a[1][8:], b[1][9:]))
            i += 2
        else:
            i += 1
    if not hunks:
        continue
    out.append(f"\n================ FILE: {f}  ({len(hunks)} hunks) ================")
    for n, (start, end, ours_label, theirs_label) in enumerate(hunks, 1):
        lo, hi = ctx_lines(lines, start, end)
        out.append(f"\n---- {f} hunk {n}: ours={ours_label} theirs={theirs_label} lines {start+1}..{end+1} ----")
        for k in range(lo, hi):
            tag = " "
            if k == start:
                tag = "!"
            if start < k < end and lines[k].startswith("======="):
                tag = "|"
            out.append(f"{k+1:6}{tag} {lines[k]}")

open("conflict-dump.txt", "w", encoding="utf-8", newline="\n").write("\n".join(out))
print(f"dumped {len(files)} files -> conflict-dump.txt ({len(out)} lines)")