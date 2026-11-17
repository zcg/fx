import subprocess

BASE = "e7a69e5c"
files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()

print(f"{'file':52} {'ours':>12} {'theirs':>12}  verdict")
for f in files:
    def numstat(side):
        r = subprocess.run(["git", "diff", "--numstat", f"{BASE}...{side}", "--", f],
                           capture_output=True, text=True)
        line = r.stdout.strip().split("\n")[0] if r.stdout.strip() else "0\t0"
        p = line.split("\t")
        a, d = p[0], p[1]
        return f"+{a}/-{d}"
    ours, theirs = numstat("HEAD"), numstat("origin/main")
    print(f"{f:52} {ours:>12} {theirs:>12}")