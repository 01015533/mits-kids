#!/usr/bin/env python3
"""Run known security fixtures only in the explicitly selected validation AVD app.

Build the dedicated debug probe first; see docs/SECURITY-PERSISTENCE-TESTS.md.
No production package, PIN, signing key, system clock or physical device is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

VALIDATION_PACKAGE = "com.example.mits_kids_youtube.validation"
LEGACY_FIXTURE_PIN = "4826"
STAGE_FILE = "app_flutter/security-validation-stage.json"
RESULT_FILE = "app_flutter/security-validation-result.json"


def validate_target(serial: str, package: str, reset: bool) -> None:
    if not re.fullmatch(r"emulator-[0-9]+", serial):
        raise ValueError("Only an explicitly named local emulator is accepted.")
    if package != VALIDATION_PACKAGE:
        raise ValueError("Only the hardcoded disposable validation package is accepted.")
    if not reset:
        raise ValueError("--reset-validation-data is required; only disposable fixture data is cleared.")


class Runner:
    def __init__(self, adb: Path, serial: str, evidence: Path):
        self.adb = adb
        self.serial = serial
        self.evidence = evidence
        self.results: list[dict] = []
        self.component = ""

    def command(self, *arguments: str, data: str | None = None,
                timeout: float = 30, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.adb), "-s", self.serial, *arguments],
                                input=data, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            # Payloads are never included: run-as writes contain fixture state.
            raise RuntimeError(f"ADB operation failed: {arguments[0]} (exit {result.returncode})")
        return result

    def assert_emulator(self) -> None:
        state = self.command("get-state").stdout.strip()
        qemu = self.command("shell", "getprop", "ro.kernel.qemu").stdout.strip()
        if state != "device" or qemu != "1":
            raise RuntimeError("Target is not a ready local Android emulator.")

    def write_private(self, relative_path: str, value: str) -> None:
        allowed = {STAGE_FILE, "shared_prefs/FlutterSharedPreferences.xml",
                   "shared_prefs/mits_parent_v2.xml"}
        if relative_path not in allowed:
            raise ValueError("Refusing an unrecognized fixture write path.")
        script = f"cat > {shlex.quote(relative_path)}"
        self.command("shell", f"run-as {VALIDATION_PACKAGE} sh -c {shlex.quote(script)}", data=value)

    def force_stop(self) -> None:
        self.command("shell", "am", "force-stop", VALIDATION_PACKAGE)

    def stage(self, name: str, **fields: int) -> dict:
        allowed = {"migration", "seed_cooldown", "process_probe", "wall_deadline_probe",
                   "reboot_probe", "recover_after_cooldown"}
        if name not in allowed:
            raise ValueError("Unknown validation stage.")
        self.force_stop()
        self.command("shell", "run-as", VALIDATION_PACKAGE, "rm", "-f", RESULT_FILE)
        self.write_private(STAGE_FILE, json.dumps({"stage": name, **fields}))
        print(f"START {name}", flush=True)
        started = time.monotonic()
        self.command("shell", "am", "start", "-W", "-n", self.component, timeout=30)
        while time.monotonic() - started < 100:
            response = self.command("exec-out", "run-as", VALIDATION_PACKAGE,
                                    "cat", RESULT_FILE, check=False)
            # adb exec-out can return zero while remote cat reports ENOENT on
            # stdout. The probe atomically publishes a JSON object when ready.
            if response.returncode == 0 and response.stdout.lstrip().startswith("{"):
                result = json.loads(response.stdout)
                result["host_elapsed_seconds"] = round(time.monotonic() - started, 3)
                (self.evidence / f"{name}.json").write_text(json.dumps(result, indent=2) + "\n")
                self.results.append(result)
                if result.get("result") != "PASS" or result.get("stage") != name:
                    raise RuntimeError(f"{name} failed: {result.get('detail', 'invalid result')}")
                print(f"PASS {name}: {json.dumps(result, sort_keys=True)}", flush=True)
                return result
            time.sleep(0.2)
        raise RuntimeError(f"{name} timed out. Ensure the emulator is unlocked and the dedicated probe APK was supplied.")

    def simulate_expired_wall_deadline(self) -> None:
        self.force_stop()
        source = self.command("exec-out", "run-as", VALIDATION_PACKAGE, "cat",
                              "shared_prefs/mits_parent_v2.xml").stdout
        preferences = ET.fromstring(source)
        fields = {entry.attrib.get("name"): entry for entry in preferences}
        failures = fields.get("failures")
        wall = fields.get("untilWall")
        if failures is None or failures.attrib.get("value") != "5" or wall is None:
            raise RuntimeError("Expected only the known five-failure validation fixture.")
        elapsed_before = fields["untilElapsed"].attrib["value"]
        boot_before = fields["boot"].attrib["value"]
        wall.set("value", "0")
        assert fields["untilElapsed"].attrib["value"] == elapsed_before
        assert fields["boot"].attrib["value"] == boot_before
        # Fixture verifier material remains in memory only and is never logged.
        self.write_private("shared_prefs/mits_parent_v2.xml", ET.tostring(preferences, encoding="unicode"))
        print("Fixture simulation: only validation untilWall set to 0; no system clock changed.", flush=True)

    def reboot(self) -> tuple[int, int]:
        before = int(self.command("shell", "settings", "get", "global", "boot_count").stdout.strip())
        self.force_stop()
        self.command("reboot")
        self.command("wait-for-device", timeout=120)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            result = self.command("shell", "getprop", "sys.boot_completed", check=False)
            if result.stdout.strip() == "1":
                self.assert_emulator()
                after = int(self.command("shell", "settings", "get", "global", "boot_count").stdout.strip())
                if after <= before:
                    raise RuntimeError("Emulator boot count did not increase.")
                return before, after
            time.sleep(1)
        raise RuntimeError("Emulator reboot did not complete within the bounded wait.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", required=True)
    parser.add_argument("--package", required=True, choices=[VALIDATION_PACKAGE])
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--reset-validation-data", action="store_true", required=True)
    parser.add_argument("--reboot-emulator", action="store_true")
    parser.add_argument("--simulate-wall-deadline", action="store_true")
    parser.add_argument("--sdk", type=Path, default=Path(os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Android/Sdk"))))
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args(argv)
    validate_target(args.emulator, args.package, args.reset_validation_data)
    apk = args.apk.resolve(strict=True)
    analyzer = args.sdk / "cmdline-tools/latest/bin/apkanalyzer"
    # This identity check happens BEFORE install or any package/data mutation.
    package = subprocess.run([str(analyzer), "manifest", "application-id", str(apk)],
                             check=True, capture_output=True, text=True, timeout=60).stdout.strip()
    if package != VALIDATION_PACKAGE:
        raise ValueError("APK is not the isolated validation package; refusing installation.")
    evidence = args.evidence_dir or Path(tempfile.mkdtemp(prefix="mits-security-validation-"))
    evidence.mkdir(parents=True, exist_ok=True)
    runner = Runner(args.sdk / "platform-tools/adb", args.emulator, evidence)
    runner.assert_emulator()
    runner.command("install", "-r", str(apk), timeout=90)
    runner.force_stop()
    if runner.command("shell", "pm", "clear", VALIDATION_PACKAGE).stdout.strip() != "Success":
        raise RuntimeError("Could not clear the disposable validation fixture.")
    runner.command("shell", "run-as", VALIDATION_PACKAGE, "mkdir", "-p", "shared_prefs", "app_flutter")
    fixture_hash = hashlib.sha256(LEGACY_FIXTURE_PIN.encode("ascii")).hexdigest()
    runner.write_private("shared_prefs/FlutterSharedPreferences.xml",
                         '<?xml version="1.0" encoding="utf-8"?><map><string name="flutter.parent_pin_sha256_v1">'
                         + fixture_hash + '</string></map>')
    component = runner.command("shell", "cmd", "package", "resolve-activity", "--brief",
                               VALIDATION_PACKAGE).stdout.strip().splitlines()[-1]
    if not re.fullmatch(re.escape(VALIDATION_PACKAGE) + r"/[A-Za-z0-9_.$]+", component):
        raise RuntimeError("Could not resolve the isolated validation activity.")
    runner.component = component
    try:
        runner.stage("migration")
        seeded = runner.stage("seed_cooldown")
        runner.stage("process_probe", previous_pid=seeded["pid"])
        if args.simulate_wall_deadline:
            runner.simulate_expired_wall_deadline()
            runner.stage("wall_deadline_probe")
        if args.reboot_emulator:
            before, after = runner.reboot()
            runner.stage("reboot_probe", boot_before=before, boot_after=after)
        else:
            runner.stage("recover_after_cooldown")
            print("NOT TESTED: reboot persistence (use --reboot-emulator).", flush=True)
        summary = {"result": "PASS", "package": VALIDATION_PACKAGE, "emulator": args.emulator,
                   "apk_sha256": hashlib.file_digest(apk.open("rb"), "sha256").hexdigest(),
                   "reboot_tested": args.reboot_emulator, "wall_deadline_simulated": args.simulate_wall_deadline,
                   "actual_system_clock_changed": False, "stages": runner.results}
        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"Security persistence evidence: {evidence}", flush=True)
        return 0
    finally:
        runner.force_stop()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as failure:
        print(f"STOP: {failure}", file=sys.stderr)
        raise SystemExit(1)
