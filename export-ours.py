import os, subprocess

BASE = "e7a69e5c"
files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()

os.makedirs("ourside", exist_ok=True)
total = 0
for f in files:
    r = subprocess.run(["git", "diff", f"{BASE}...HEAD", "--", f],
                       capture_output=True, text=True)
    safe = f.replace("/", "__")
    with open(f"ourside/{safe}.diff", "w", encoding="utf-8", newline="\n") as fh:
        fh.write(r.stdout)
    total += r.stdout.count("\n")
print(f"exported {len(files)} diffs, {total} total diff lines")