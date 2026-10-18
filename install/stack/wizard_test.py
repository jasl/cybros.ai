#!/usr/bin/env python3
"""Offline PTY behavior tests, invoked by test.sh with its mock Docker on PATH."""

import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().with_name("install.sh")
TIMEOUT = 10


class PipedWizard:
    """Give the shell a controlling terminal, but put installer source on stdin."""

    def __init__(self, arguments, environment, directory, command=None):
        self.output = ""
        self.cursor = 0
        self.status = None
        self.eof = False
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.chdir(directory)
            os.execve(
                "/bin/sh",
                command or ["sh", "-c", 'installer=$1; shift; cat "$installer" | sh -s -- "$@"',
                            "wizard-test", str(INSTALLER), *arguments],
                environment,
            )

    def read(self, timeout):
        if self.eof or not select.select([self.terminal], [], [], timeout)[0]:
            return
        try:
            data = os.read(self.terminal, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            self.output += data.decode("utf-8", errors="replace")
        else:
            self.eof = True

    def poll(self):
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status

    def expect(self, prompt):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            position = self.output.find(prompt, self.cursor)
            if position >= 0:
                self.cursor = position + len(prompt)
                return
            self.read(0.1)
            if self.poll() is not None and self.eof:
                break
        raise AssertionError(f"Did not receive {prompt!r}:\n{self.output}")

    def answer(self, prompt, value=""):
        self.expect(prompt)
        os.write(self.terminal, (value + "\n").encode())

    def finish(self):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            self.read(0.1)
            if self.poll() is not None and self.eof:
                return self.status, self.output
        raise AssertionError(f"Installer did not exit:\n{self.output}")

    def close(self):
        if self.poll() is None:
            os.killpg(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.terminal)


class WizardTest(unittest.TestCase):
    def setUp(self):
        self.assertIn("TEST_DOCKER_LOG", os.environ, "Run this suite with install/stack/test.sh")
        temporary = tempfile.TemporaryDirectory(prefix="cybros-wizard-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / "installation with spaces"
        self.log = self.root / "docker.log"
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CYBROS_", "TEST_"))
        }
        self.environment.update(
            TEST_DOCKER_LOG=str(self.log), TEST_CMCTL_STDIN=str(self.root / "cmctl.stdin"),
            TEST_SETUP_STDIN=str(self.root / "setup.stdin"),
        )

    def wizard(self, *arguments, settings=None):
        process = PipedWizard(arguments, self.environment | (settings or {}), self.root)
        self.addCleanup(process.close)
        return process

    def headless(self, *arguments, settings=None):
        # A new session has no controlling terminal, even when test.sh runs in one.
        return subprocess.run(
            ["/bin/sh", "-s", "--", *arguments], input=INSTALLER.read_bytes(),
            env=self.environment | (settings or {}), cwd=self.root,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True, timeout=TIMEOUT, check=False,
        )

    def settings(self, filename=".env"):
        return dict(
            line.split("=", 1) for line in (self.directory / filename).read_text().splitlines()
            if line and not line.startswith("#")
        )

    def assert_config(self, **expected):
        settings = self.settings()
        for key, value in expected.items():
            self.assertEqual(settings[key], repr(value), key)

    def assert_no_start(self):
        log = self.log.read_text()
        self.assertNotIn(" pull\n", log)
        self.assertNotIn(" up -d ", log)
        self.assertNotIn(" rho setup ", log)

    def assert_rho_link(self, output, base_url):
        self.assertIn(base_url, output, "missing public rho URL")
        self.assertNotIn("#code=", output)
        self.assertIn("Create your administrator account", output)
        self.assertNotIn("Setup secret", output)
        self.assertNotIn("setup_secret=", output)
        self.assertNotIn("NEXUS_SETUP_SECRET", self.settings("secrets.env"))

    def test_local_pipe_install_uses_terminal_answers_and_starts(self):
        process = self.wizard("--dir", str(self.directory), settings={"SSH_CONNECTION": "", "SSH_TTY": "", "DISPLAY": ":test"})
        process.answer("Access [1]: ")
        process.answer("Nexus port [3300]: ")
        process.answer("rho port [7777]: ")
        process.answer("Install and start Cybros? [Y/n]: ")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assert_config(
            CYBROS_BIND="127.0.0.1", CYBROS_NEXUS_PORT="3300", CYBROS_RHO_PORT="7777",
            CYBROS_NEXUS_URL="http://localhost:3300", CYBROS_RHO_URL="http://localhost:7777",
        )
        calls = self.log.read_text().splitlines()
        self.assertTrue(any(call.endswith(" pull") for call in calls))
        self.assertTrue(any(" up -d --wait " in call for call in calls))
        self.assertFalse(any("--profile setup" in call for call in calls))
        self.assertTrue((self.directory / "secrets.env").is_file())
        self.assertFalse((self.directory / "setup.rb").exists())
        self.assert_rho_link(output, "http://localhost:7777")
        self.assertNotIn(" rho setup ", self.log.read_text())
        self.assertNotIn("Configure test model", output)
        self.assertNotIn("--force-recreate", self.log.read_text())
        self.assertEqual(
            Path(str(self.log) + ".browser").read_text(),
            "http://localhost:7777\n",
        )

    def test_remote_install_prints_the_saved_public_rho_link_without_opening_a_browser(self):
        process = self.wizard(
            "--yes", "--dir", str(self.directory),
            settings={
                "SSH_CONNECTION": "client 1234 server 22", "DISPLAY": ":test",
                "CYBROS_RHO_URL": "https://rho.example/console/",
                "CYBROS_NEXUS_URL": "https://nexus.example/",
            },
        )
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assert_rho_link(output, "https://rho.example/console")
        self.assertFalse(Path(str(self.log) + ".browser").exists())

    def test_manual_setup_uses_terminal_and_applies_without_restarting_the_daemon(self):
        result = self.headless("--yes", "--no-start", "--dir", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.log.write_text("")
        process = PipedWizard(
            [], self.environment, self.root,
            command=["sh", str(self.directory / "cybros"), "setup"],
        )
        self.addCleanup(process.close)
        process.answer("Configure test model [Y/n]: ", "y")
        process.answer("Your Telegram numeric user ID: ", "123456")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assertIn("exec -e CMCTL_HOME=/var/lib/rho/cmctl rho rho setup --nexus-url http://nexus --public-url http://localhost:3300", self.log.read_text())
        self.assertNotIn("--force-recreate", self.log.read_text())
        self.assertEqual((self.root / "setup.stdin").read_text(), "y\n")
        self.assertEqual((self.root / "setup.stdin.finish").read_text(), "123456\n")
        calls = self.log.read_text().splitlines()
        first_setup = next(i for i, line in enumerate(calls) if "--public-url" in line)
        finish = next(i for i, line in enumerate(calls) if "setup telegram --finish" in line)
        self.assertLess(first_setup, finish)
        self.assertIn("applied the saved settings", output)

    def test_setup_repeats_one_section_and_preserves_config_without_restarts(self):
        result = self.headless("--yes", "--no-start", "--dir", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        before = {name: (self.directory / name).read_bytes() for name in (".env", "secrets.env")}
        for failure in (True, False):
            with self.subTest(failure=failure):
                self.log.write_text("")
                process = PipedWizard(
                    [], self.environment | {"TEST_SETUP_FAIL": "1" if failure else "0"}, self.root,
                    command=["sh", str(self.directory / "cybros"), "setup", "telegram"],
                )
                self.addCleanup(process.close)
                process.answer("Configure test model [Y/n]: ", "keep")
                if not failure:
                    process.answer("Your Telegram numeric user ID: ", "123456")
                status, output = process.finish()
                self.assertEqual(status, 1 if failure else 0, output)
                self.assertIn("--public-url http://localhost:3300 telegram", self.log.read_text())
                self.assertNotIn("--force-recreate", self.log.read_text())
                self.assertEqual(before, {name: (self.directory / name).read_bytes() for name in before})

    def test_setup_without_terminal_reports_resume_without_restarting_services(self):
        result = self.headless("--yes", "--no-start", "--dir", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.log.write_text("")
        result = subprocess.run(
            ["sh", str(self.directory / "cybros"), "setup"], input=b"",
            env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True, timeout=TIMEOUT, check=False,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout.decode())
        self.assertIn("Setup needs an interactive terminal", result.stdout.decode())
        self.assert_no_start()

    def test_home_server_uses_hostname_and_custom_ports_without_starting(self):
        process = self.wizard("--dir", str(self.directory), "--no-start")
        process.answer("Access [1]: ", "2")
        process.answer("Server hostname or IPv4 address: ", "home.local")
        process.answer("Nexus port [3300]: ", "4330")
        process.answer("rho port [7777]: ", "8777")
        process.answer("Create configuration? [Y/n]: ", "y")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assertNotIn("Installation directory [", output)
        self.assert_config(
            CYBROS_BIND="0.0.0.0", CYBROS_NEXUS_PORT="4330", CYBROS_RHO_PORT="8777",
            CYBROS_NEXUS_URL="http://home.local:4330", CYBROS_RHO_URL="http://home.local:8777",
        )
        self.assert_no_start()

    def test_lan_bind_prompts_for_missing_browser_address(self):
        process = self.wizard(
            "--dir", str(self.directory), "--no-start", settings={"CYBROS_BIND": "0.0.0.0"}
        )
        process.answer("Server hostname or IPv4 address: ", "home.local")
        process.answer("Nexus port [3300]: ")
        process.answer("rho port [7777]: ")
        process.answer("Create configuration? [Y/n]: ")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assertNotIn("Access [", output)
        self.assert_config(
            CYBROS_BIND="0.0.0.0", CYBROS_NEXUS_URL="http://home.local:3300",
            CYBROS_RHO_URL="http://home.local:7777",
        )
        self.assert_no_start()

    def test_partial_local_url_keeps_explicit_url_and_fills_missing_url(self):
        process = self.wizard(
            "--dir", str(self.directory), "--no-start",
            settings={"CYBROS_NEXUS_URL": "http://localhost:4330"},
        )
        process.answer("Server hostname or IPv4 address: ", "localhost")
        process.answer("Nexus port [3300]: ", "4330")
        process.answer("rho port [7777]: ")
        process.answer("Create configuration? [Y/n]: ")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        self.assert_config(
            CYBROS_BIND="127.0.0.1", CYBROS_NEXUS_PORT="4330",
            CYBROS_NEXUS_URL="http://localhost:4330", CYBROS_RHO_URL="http://localhost:7777",
        )
        self.assert_no_start()

    def test_cancel_before_install_leaves_no_directory(self):
        process = self.wizard("--dir", str(self.directory))
        process.answer("Access [1]: ")
        process.answer("Nexus port [3300]: ")
        process.answer("rho port [7777]: ")
        process.answer("Install and start Cybros? [Y/n]: ", "n")
        process.finish()
        self.assertFalse(self.directory.exists())
        self.assert_no_start()

    def test_terminal_eof_before_confirmation_leaves_no_directory(self):
        process = self.wizard("--dir", str(self.directory), "--no-start")
        process.answer("Access [1]: ")
        process.answer("Nexus port [3300]: ")
        process.answer("rho port [7777]: ")
        process.expect("Create configuration? [Y/n]: ")
        os.write(process.terminal, b"\x04")
        status, output = process.finish()
        self.assertNotEqual(status, 0, output)
        self.assertFalse(self.directory.exists())
        self.assert_no_start()

    def test_headless_new_install_requires_explicit_yes(self):
        result = self.headless("--dir", str(self.directory), "--no-start")
        self.assertNotEqual(result.returncode, 0, result.stdout.decode())
        self.assertIn("--yes", result.stdout.decode())
        self.assertFalse(self.directory.exists())

    def test_yes_preserves_explicit_environment_and_directory_flag_precedence(self):
        environment_directory = self.root / "ignored environment directory"
        result = self.headless(
            "--yes", "--no-start", "--dir", str(self.directory),
            settings={
                "CYBROS_INSTALL_DIR": str(environment_directory),
                "CYBROS_BIND": "127.0.0.1", "CYBROS_NEXUS_PORT": "4330",
                "CYBROS_RHO_PORT": "8777", "CYBROS_NEXUS_URL": "https://nexus.example.test",
                "CYBROS_RHO_URL": "https://rho.example.test", "CYBROS_IMAGE_TAG": "2610080749",
            },
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.assertFalse(environment_directory.exists())
        self.assert_config(
            CYBROS_BIND="127.0.0.1", CYBROS_NEXUS_PORT="4330", CYBROS_RHO_PORT="8777",
            CYBROS_NEXUS_URL="https://nexus.example.test", CYBROS_RHO_URL="https://rho.example.test",
            CYBROS_IMAGE_TAG="2610080749",
        )
        self.assert_no_start()

    def test_interactive_explicit_settings_skip_questions_and_reinstall_preserves_files(self):
        settings = {
            "CYBROS_INSTALL_DIR": str(self.directory), "CYBROS_BIND": "0.0.0.0",
            "CYBROS_NEXUS_PORT": "4330", "CYBROS_RHO_PORT": "8777",
            "CYBROS_NEXUS_URL": "http://home.local:4330", "CYBROS_RHO_URL": "http://home.local:8777",
        }
        process = self.wizard("--no-start", settings=settings)
        process.answer("Create configuration? [Y/n]: ")
        status, output = process.finish()
        self.assertEqual(status, 0, output)
        for prompt in ("Installation directory [", "Access [", "Nexus port [", "rho port ["):
            self.assertNotIn(prompt, output)
        self.assert_config(**{key: value for key, value in settings.items() if key != "CYBROS_INSTALL_DIR"})
        files = (".env", "secrets.env", "compose.yaml", "cybros")
        before = {name: (self.directory / name).read_bytes() for name in files}
        result = self.headless(
            "--dir", str(self.directory), "--no-start", settings={"CYBROS_NEXUS_PORT": "9999"}
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.assertEqual(before, {name: (self.directory / name).read_bytes() for name in files})
        self.assert_no_start()


if __name__ == "__main__":
    unittest.main(verbosity=2)
