#!/usr/bin/env python3
"""Exercise the actual PowerShell configure prompts in a POSIX PTY.

Requires PowerShell Core: MCP_POWERSHELL=/path/to/pwsh python3 tests/test-local-configure.py
This is not a substitute for a native Windows/PowerShell 5.1 test.
"""
from __future__ import annotations

import fcntl
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
POWERSHELL = os.environ.get("MCP_POWERSHELL", "pwsh")


def run_configure(base: pathlib.Path, allow: str) -> tuple[int, str]:
    env = {**os.environ, "OS": "Windows_NT", "MCP_LOCAL_DIR": str(base), "TERM": "dumb"}
    subprocess.run(
        [POWERSHELL, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "windows/run-local.ps1", "init"],
        cwd=ROOT, env=env, check=True, capture_output=True,
    )
    # A PTY is needed because configure refuses redirected input. Respond to
    # console cursor-position queries used by older PowerShell versions.
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    command = "Remove-Module PSReadLine -ErrorAction SilentlyContinue; & ./windows/run-local.ps1 configure"
    process = subprocess.Popen(
        [POWERSHELL, "-NoLogo", "-NoProfile", "-Command", command],
        cwd=ROOT, env=env, stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    answers = [
        ("Windows gateway listen address", "10.55.0.2"),
        ("Gateway base URL reachable", "http://10.55.0.2:13001"),
        ("TLS certificate PEM path", ""),
        ("TLS private key PEM path", ""),
        ("MetaMCP account email", "alice@example.com"),
        ("Linux SSH destination", "alice@linux.example.com"),
        ("Absolute path to this repository", "/home/alice/mcp-kit"),
        ("Type YES to allow", allow),
    ]
    transcript = ""
    pending = ""
    step = 0
    deadline = time.monotonic() + 25
    try:
        while time.monotonic() < deadline and process.poll() is None:
            if not select.select([master], [], [], 0.25)[0]:
                continue
            try:
                chunk = os.read(master, 65536).decode("utf-8", errors="replace")
            except OSError:
                break
            transcript += chunk
            pending += chunk
            if "\x1b[6n" in pending:
                os.write(master, b"\x1b[1;1R")
                pending = pending.replace("\x1b[6n", "")
            if step < len(answers) and answers[step][0] in pending:
                os.write(master, (answers[step][1] + "\n").encode())
                step += 1
                pending = ""
        process.wait(timeout=5)
        assert step == len(answers), f"Only {step} prompts answered: {transcript}"
        return process.returncode, transcript
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mcpkit-configure-") as folder:
        base = pathlib.Path(folder) / "profile with spaces"
        code, text = run_configure(base, "YES")
        assert code == 0, text
        settings = json.loads((base / "config" / "local-settings.json").read_text(encoding="utf-8"))
        assert settings["listenHost"] == "10.55.0.2"
        assert settings["advertiseBaseUrl"] == "http://10.55.0.2:13001"
        assert settings["allowInsecureLan"] is True
        assert settings["metamcpOwnerEmail"] == "alice@example.com"
        assert settings["linuxKitDir"] == "/home/alice/mcp-kit"
        assert "Saved " in text

        refused = pathlib.Path(folder) / "refused"
        code, text = run_configure(refused, "NO")
        assert code != 0, text
        settings = json.loads((refused / "config" / "local-settings.json").read_text(encoding="utf-8"))
        assert settings["listenHost"] == "127.0.0.1"
        assert settings["advertiseBaseUrl"] == ""
        assert settings["allowInsecureLan"] is False
        print("PowerShell interactive configure: VPN opt-in saved; refusal preserved the existing settings.")


if __name__ == "__main__":
    main()
