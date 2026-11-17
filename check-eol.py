import subprocess

CRLF = bytes([13, 10])
LF = bytes([10])

files = [
    "src/builtins/system_prompt.md",
    "tests/e2e/web-fetch-live.test.ts",
    "tests/evals/eval-helpers.ts",
]

for f in files:
    old = subprocess.run(["git", "cat-file", "-p", "HEAD:" + f],
                         capture_output=True, check=True).stdout
    new = subprocess.run(["git", "cat-file", "-p", ":" + f],
                         capture_output=True, check=True).stdout
    oldn = old.replace(CRLF, LF)
    newn = new.replace(CRLF, LF)
    print("%-45s CRLF_old=%4d CRLF_new=%4d content_identical=%s"
          % (f, old.count(CRLF), new.count(CRLF), oldn == newn))