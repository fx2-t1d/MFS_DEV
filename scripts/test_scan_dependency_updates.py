import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import scan_dependency_updates as scan


class DependencyScanTest(unittest.TestCase):
    def test_flags_added_sensitive_code_and_obfuscation(self):
        diff = """diff --git a/example.swift b/example.swift
--- a/example.swift
+++ b/example.swift
@@ -1,2 +1,4 @@
-let old = URLSession.shared
+let value = 42
+let location = CLLocationManager()
+let request = URLSession.shared
+let payload = "%s"
""" % ("A" * 200)
        findings = scan.scan_diff(diff, "LoopKit")
        self.assertEqual(
            {item[1] for item in findings},
            {"sensitive data or device access", "network access", "encoded or unusually dense content"},
        )
        self.assertTrue(any("example.swift:2" in item[2] for item in findings))

    def test_ignores_removed_code_and_marks_binary_and_nested_changes(self):
        diff = """diff --git a/file.rb b/file.rb
--- a/file.rb
+++ b/file.rb
@@ -1 +1 @@
-system("old")
+puts "safe"
diff --git a/image.png b/image.png
Binary files a/image.png and b/image.png differ
diff --git a/vendor b/vendor
--- a/vendor
+++ b/vendor
@@ -1 +1 @@
-Subproject commit 123
+Subproject commit 456
"""
        self.assertEqual(
            {item[1] for item in scan.scan_diff(diff, "LoopKit")},
            {"binary file changed", "nested submodule changed; not scanned"},
        )

    def test_scans_real_submodule_commit_diff_and_stops_before_merge(self):
        env = dict(os.environ, GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com",
                   GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.com",
                   GIT_ALLOW_PROTOCOL="file")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, app = root / "source", root / "app"
            source.mkdir()
            app.mkdir()

            def git(cwd, *args):
                subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

            git(source, "init", "-q")
            (source / "file.swift").write_text("let x = 1\n")
            git(source, "add", ".")
            git(source, "commit", "-qm", "base")
            git(app, "init", "-q")
            git(app, "submodule", "add", "-q", str(source), "LoopKit")
            git(app, "commit", "-qam", "submodule")
            (source / "file.swift").write_text("let x = 1\nlet location = CLLocationManager()\n")
            git(source, "commit", "-qam", "update")
            git(app / "LoopKit", "fetch", "-q", "origin", "HEAD")
            git(app / "LoopKit", "checkout", "-q", "--detach", "FETCH_HEAD")
            old_cwd = os.getcwd()
            try:
                os.chdir(app)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(1, scan.main(["LoopKit"]))
                self.assertIn("sensitive data or device access", output.getvalue())
            finally:
                os.chdir(old_cwd)

    def test_fastlane_compares_original_and_updated_gem_without_installing(self):
        original = 'gem "fastlane", "2.0.0"\n'
        with tempfile.TemporaryDirectory() as directory:
            gemfile = Path(directory) / "Gemfile"
            gemfile.write_text('gem "fastlane", "2.1.0"\n')
            old_cwd = os.getcwd()
            try:
                os.chdir(directory)
                with patch.object(scan, "command", side_effect=[original, "", "", "", "", "diff"]) as cmd:
                    self.assertEqual("diff", scan.fastlane_diff())
                commands = [call.args[0] for call in cmd.call_args_list]
                self.assertEqual(2, sum(args[:2] == ["gem", "fetch"] for args in commands))
                self.assertEqual(2, sum(args[:2] == ["gem", "unpack"] for args in commands))
                self.assertFalse(any(args[:2] == ["gem", "install"] for args in commands))
            finally:
                os.chdir(old_cwd)


if __name__ == "__main__":
    unittest.main()
