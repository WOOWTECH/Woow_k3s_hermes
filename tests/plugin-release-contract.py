#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "stage-optional-plugins.py"
LOCK = json.loads((ROOT / "plugins" / "lock.json").read_text())
SPEC = importlib.util.spec_from_file_location("stage_optional_plugins", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class PluginReleaseContract(unittest.TestCase):
    def test_exact_compatibility_lock(self):
        self.assertEqual(LOCK["hermes"]["version"], "0.22.5")
        paseo = LOCK["plugins"]["hermes-paseo"]
        self.assertEqual(paseo["version"], "0.1.5-rc.3")
        self.assertEqual(paseo["commit"], "7b9c88d032672f688c88df222e384ce3bc1af2f2")
        self.assertEqual(paseo["runtime"], "0.11.2-r3-523d451cc096")
        self.assertNotIn("0.17.4", paseo["runtime"])
        omni = LOCK["plugins"]["hermes-omnigent"]
        self.assertEqual(omni["version"], "0.1.0-rc.21")
        self.assertEqual(omni["commit"], "84e0c41ce91594908a53c91fcff09123ca92f626")

    def make_archive(self, path: Path, plugin: str, version: str) -> str:
        payload = f"name: {plugin}\nversion: {version}\n".encode()
        with tarfile.open(path, "w:gz") as archive:
            info = tarfile.TarInfo("source/plugin.yaml")
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_stages_without_profile_mutation_or_enablement(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            archive = temp / "source.tar.gz"
            digest = self.make_archive(archive, "hermes-paseo", "0.1.5-rc.3")
            data = json.loads(json.dumps(LOCK))
            data["plugins"]["hermes-paseo"]["archive_sha256"] = digest
            original_loader = MODULE.load_lock
            MODULE.load_lock = lambda: data
            try:
                output = temp / "staged"
                MODULE.stage("hermes-paseo", output, archive)
                receipt = json.loads((output / "WOOWTECH-SOURCE-RECEIPT.json").read_text())
                self.assertFalse(receipt["installed"])
                self.assertFalse(receipt["enabled"])
                self.assertFalse(receipt["paired"])
                with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                    MODULE.stage("hermes-paseo", output, archive)
                with self.assertRaisesRegex(ValueError, "live Hermes profile path"):
                    MODULE.stage("hermes-paseo", temp / "plugins" / "hermes-paseo", archive)
            finally:
                MODULE.load_lock = original_loader


if __name__ == "__main__":
    unittest.main()
