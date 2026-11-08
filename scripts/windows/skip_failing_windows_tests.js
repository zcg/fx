//! Adds a Windows skip to the test blocks that fail to compile on Windows.
//!
//! The suites under `src/` model POSIX behavior: a pid is a number, a signal is
//! `std.posix.SIG.KILL`, and a descriptor is an fd. Windows has none of that,
//! so those blocks do not compile there. This walks a compiler error log, finds
//! the `test "..."` block each error belongs to, and inserts one guarded skip
//! at the top of the block. Windows coverage is written separately against
//! Windows behavior.
//!
//! Usage: node skip_failing_windows_tests.js <error-log> [--write]

const fs = require("fs");

function lineStarts(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === "\n") starts.push(i + 1);
  return starts;
}

/// The 0-based line index of the `test "` that opens the block holding `line`.
function enclosingTest(lines, line) {
  for (let i = line; i >= 0; i--) {
    if (/^test "/.test(lines[i])) return i;
    // A top-level declaration means the error is not inside a test.
    if (/^(pub )?(const|fn|var) /.test(lines[i])) return -1;
  }
  return -1;
}

function main() {
  const logPath = process.argv[2];
  const write = process.argv.includes("--write");
  if (!logPath) {
    console.error("usage: skip_failing_windows_tests.js <error-log> [--write]");
    process.exit(2);
  }

  const byFile = new Map();
  for (const raw of fs.readFileSync(logPath, "utf8").split(/\r?\n/)) {
    const match = /^(src\\[^:]+):(\d+):\d+: error:/.exec(raw.trim());
    if (!match) continue;
    const file = match[1].replaceAll("\\", "/");
    const line = Number(match[2]) - 1;
    if (!byFile.has(file)) byFile.set(file, new Set());
    byFile.get(file).add(line);
  }

  const skipLine = '    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;';

  for (const [file, errorLines] of byFile) {
    if (!fs.existsSync(file)) {
      console.log(`${file}: missing`);
      continue;
    }
    const src = fs.readFileSync(file, "utf8");
    const lines = src.split("\n");
    const starts = new Set();
    let outside = 0;
    for (const line of errorLines) {
      const testLine = enclosingTest(lines, line);
      if (testLine < 0) {
        outside++;
        continue;
      }
      starts.add(testLine);
    }
    if (starts.size === 0) {
      console.log(`${file}: ${errorLines.size} error(s), none inside a test`);
      continue;
    }

    // Insert after the `{` that opens each test body, bottom-up so indices hold.
    const inserts = [];
    for (const testLine of starts) {
      const body = lines[testLine].indexOf("{");
      if (body < 0) {
        // The brace is on the next line.
        for (let i = testLine + 1; i < Math.min(testLine + 4, lines.length); i++) {
          const at = lines[i].indexOf("{");
          if (at >= 0) {
            inserts.push({ line: i, at });
            break;
          }
        }
        continue;
      }
      inserts.push({ line: testLine, at: body });
    }
    inserts.sort((a, b) => b.line - a.line || b.at - a.at);
    let added = 0;
    for (const { line, at } of inserts) {
      const head = lines[line].slice(0, at + 1);
      const tail = lines[line].slice(at + 1);
      lines[line] = head + "\n" + skipLine + tail;
      added++;
    }
    console.log(`${file}: ${added} test(s) skipped, ${outside} error(s) outside a test`);

    if (write) fs.writeFileSync(file, lines.join("\n"));
  }
}

main();
