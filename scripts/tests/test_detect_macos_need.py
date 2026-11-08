from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "detect-macos-need.sh"
PLATFORM_LIST = "tests/e2e/macos-platform-tests.json"


def posix_path(path: pathlib.Path | str, bash: str) -> str:
    """`path` as the Bash being used sees it.

    CI runs on Linux and macOS, where a POSIX path is already what the script
    gets. On Windows the tests run under Git Bash, which mounts the drives under
    `/d/...`, so a Windows path passed straight through names nothing there.
    """
    text = str(path)
    if os.name != "nt" or bash == "bash":
        return text
    cygpath = shutil.which("cygpath")
    if cygpath:
        result = subprocess.run(
            [cygpath, "--unix", text],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    # `cygpath` ships with Git Bash; without it, do the drive mapping by hand.
    drive = pathlib.Path(text).drive
    if len(drive) == 2 and drive[1] == ":":
        rest = text[2:].replace("\\", "/")
        return f"/{drive[0].lower()}{rest}"
    return text


def find_bash() -> str:
    """The Bash to run the script with.

    On Windows `bash` resolves to the WSL launcher in System32, which runs a
    Linux distribution that has none of this checkout's paths. The script needs
    Git Bash, so the installs Git for Windows uses are tried first.
    """
    if os.name == "nt":
        candidates = [
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files\Git\usr\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ]
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            candidates.append(
                os.path.join(local_app_data, "Programs", "Git", "bin", "bash.exe"),
            )
        # Scoop keeps Git outside the standard install folders.
        scoop = os.environ.get("SCOOP")
        if scoop:
            candidates.append(os.path.join(scoop, "apps", "git", "current", "bin", "bash.exe"))
        user_profile = os.environ.get("USERPROFILE")
        if user_profile:
            candidates.append(
                os.path.join(user_profile, "scoop", "apps", "git", "current", "bin", "bash.exe"),
            )
        for candidate in candidates:
            if os.path.exists(candidate):
                return candidate
    return "bash"

class DetectMacosNeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": self.temp.name,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        self.git("init", "-q")
        self.write(PLATFORM_LIST, '["listed.test.ts"]\n')
        self.write("src/plain.zig", "pub fn plain() void {}\n")
        self.write("src/mac.zig", "if (builtin.os.tag == .macos) {}\n")
        self.write("README.md", "fx\n")
        self.base = self.commit("base")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, check=True,
            capture_output=True, text=True,
        )
        return result.stdout.strip()

    def write(self, path: str, content: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def detect(
        self, base: str | None = None, head: str = "HEAD", **env: str,
    ) -> tuple[int, dict[str, str], str]:
        output_path = self.root.parent / f"{self.root.name}-output"
        output_path.write_text("", encoding="utf-8")
        bash = find_bash()
        result = subprocess.run(
            [bash, posix_path(SCRIPT_PATH, bash), base or self.base, head],
            cwd=self.root,
            env={**self.env, "GITHUB_OUTPUT": posix_path(output_path, bash), **env},
            capture_output=True,
            text=True,
            # Git Bash on a non-English Windows writes its diagnostics in the
            # console ANSI code page, which is not UTF-8, so a strict UTF-8
            # decode would raise before the assertion could report what ran.
            encoding="utf-8",
            errors="replace",
        )
        outputs = dict(
            line.split("=", 1)
            for line in output_path.read_text(encoding="utf-8").splitlines()
        )
        output_path.unlink()
        return result.returncode, outputs, result.stdout + result.stderr

    def assert_needed(self, *, sdk_native: bool = False, **env: str) -> str:
        code, outputs, text = self.detect(**env)
        self.assertEqual(0, code, text)
        self.assertEqual("true", outputs.get("needed"), text)
        self.assertEqual("true" if sdk_native else "false", outputs.get("sdk_native"), text)
        return text

    def assert_not_needed(self) -> None:
        code, outputs, text = self.detect()
        self.assertEqual(0, code, text)
        self.assertEqual({"needed": "false", "sdk_native": "false"}, outputs, text)

    def test_change_without_platform_behavior_skips_macos(self) -> None:
        self.write("README.md", "fx docs\n")
        self.write("src/plain.zig", "pub fn plain() u8 { return 1; }\n")
        self.write("src/linux_target.zig", "const name = .linux_x64;\n")
        self.write("tests/e2e/unlisted.test.ts", "test\n")
        self.commit("head")

        self.assert_not_needed()

    def test_a_windows_branch_needs_macos_because_the_file_still_compiles(self) -> None:
        # A Windows branch never runs on macOS, but the file that holds it still
        # has to build there, so the change is worth the macOS compile.
        self.write("src/windows.zig", "if (builtin.os.tag == .windows) {} else {}\n")
        self.commit("head")

        self.assertIn("src/windows.zig", self.assert_needed())

    def test_zig_file_with_macos_code_needs_macos(self) -> None:
        self.write("src/mac.zig", "if (builtin.os.tag == .macos) { run(); }\n")
        self.commit("head")

        self.assertIn("src/mac.zig", self.assert_needed())

    def test_linux_branch_needs_macos_because_macos_takes_the_else_path(self) -> None:
        self.write("src/self_exe.zig", "if (comptime builtin.os.tag == .linux) {} else {}\n")
        self.commit("head")

        self.assertIn("src/self_exe.zig", self.assert_needed())

    def test_linux_namespace_and_bsd_checks_need_macos(self) -> None:
        self.write("src/syscall.zig", "const pid = std.os.linux.getpid();\n")
        self.write("src/bsd.zig", "if (builtin.os.tag.isBSD()) {}\n")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/syscall.zig", text)
        self.assertIn("src/bsd.zig", text)

    def test_removing_macos_code_needs_macos(self) -> None:
        self.write("src/mac.zig", "pub fn now_plain() void {}\n")
        self.commit("head")

        self.assertIn("src/mac.zig", self.assert_needed())

    def test_deleted_and_renamed_macos_files_need_macos(self) -> None:
        self.git("mv", "src/mac.zig", "src/renamed.zig")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/mac.zig", text)
        self.assertIn("src/renamed.zig", text)

    def test_build_and_signing_changes_need_macos(self) -> None:
        for path in ("build.zig", "build.zig.zon", "scripts/sign-and-notarize-macos.sh"):
            with self.subTest(path=path):
                self.write(path, f"{path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

    def test_native_sdk_changes_also_check_the_addon(self) -> None:
        for path in ("src/napi_core_main.zig", "sdk/node.js", "sdk/tests/test-node-napi.mjs"):
            with self.subTest(path=path):
                self.write(path, f"// {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed(sdk_native=True))
                self.base = self.git("rev-parse", "HEAD")

    def test_macos_check_inputs_need_macos(self) -> None:
        self.write(".github/workflows/macos.yml", "name: macOS\n")
        self.commit("workflow")
        self.assert_needed(sdk_native=True)
        self.base = self.git("rev-parse", "HEAD")

        for path in (
            "scripts/detect-macos-need.sh",
            "scripts/smoke-binary.sh",
            "tests/e2e/ci-run-files.sh",
            "tests/e2e/ci-shards.ts",
        ):
            with self.subTest(path=path):
                self.write(path, f"# {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

    def test_listed_platform_test_needs_macos_and_nested_paths_do_not(self) -> None:
        self.write("tests/e2e/listed.test.ts", "test\n")
        self.commit("listed")
        self.assertIn("listed.test.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/fixtures/listed.test.ts", "fixture\n")
        self.commit("nested")
        self.assert_not_needed()

    def test_shared_e2e_helper_with_platform_branch_needs_macos(self) -> None:
        self.write("tests/e2e/helper.ts", 'const mac = process.platform === "darwin";\n')
        self.commit("helper")
        self.assertIn("tests/e2e/helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/helper.ts", "const mac = false;\n")
        self.commit("remove branch")
        self.assertIn("tests/e2e/helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/os-helper.ts", 'const linux = platform() === "linux";\n')
        self.commit("node:os helper")
        self.assertIn("tests/e2e/os-helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/plain.ts", "export const value = 1;\n")
        self.commit("plain helper")
        self.assert_not_needed()

    def test_requests_force_the_checks(self) -> None:
        self.assertIn("ci:macos label", self.assert_needed(MACOS_REQUESTED="ci:macos label"))
        self.assert_needed(sdk_native=True, SDK_NATIVE_REQUESTED="true")

    def test_unreadable_revision_fails_instead_of_skipping(self) -> None:
        code, outputs, text = self.detect(base="does-not-exist")

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("cannot read revision", text)

    def test_missing_platform_list_fails_instead_of_skipping(self) -> None:
        (self.root / PLATFORM_LIST).unlink()

        code, outputs, text = self.detect()

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("not a JSON array", text)


if __name__ == "__main__":
    unittest.main()
