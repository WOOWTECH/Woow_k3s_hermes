#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "hermes": "4ce75929789b63d098b8f19b489d9b6bb508b29d3f896aa2d1fc73622ca96bc8",
    "dashboard_control.py": "542cb4cd394b6c1b068723dd68cb16cdb98a77f4e7147aab3632ae8f6968d01e",
    "profile_lifecycle.py": "3768bc96572512eb8040231641fe16d39611dd9e8b16153c79d31584c0ab1b55",
    "resource_limits.py": "2195c5b2c5a88f6ddc81c24fe606b6a1911b1d7a2be6f48cc7eb86350f37512d",
}
PH = (
    "placeholders.DOMAIN=example.invalid,placeholders.DASHBOARD_PASSWORD=x,"
    "placeholders.WEBUI_PASSWORD=x,placeholders.POSTGRES_PASSWORD=x,"
    "placeholders.MINIMAX_API_KEY=x,placeholders.CF_TUNNEL_TOKEN=x"
)


def render(enabled: bool, instance: str = "adapter-test"):
    command = [
        "helm", "template", "adapter-test", str(ROOT), "-n", "adapter-test",
        "--set", f"instance={instance}",
        "--set-string", PH,
    ]
    if enabled:
        command.extend(["--set", "hermes.paseoHostAdapter.enabled=true"])
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


class PaseoHostAdapterContract(unittest.TestCase):
    def test_reviewed_files_are_byte_exact_and_auth_gated(self):
        for name, expected in FILES.items():
            payload = (ROOT / "files" / "paseo-host" / name).read_bytes()
            self.assertEqual(hashlib.sha256(payload).hexdigest(), expected, name)
        control = (ROOT / "files/paseo-host/dashboard_control.py").read_text()
        self.assertIn("server._require_token", control)
        self.assertIn("APIRouter(prefix=PREFIX)", control)
        self.assertIn("PREFIX = '/api/hermes-paseo-host'", control)
        wrapper = (ROOT / "files/paseo-host/hermes").read_text()
        self.assertIn("/command/s6-svstat", control)
        self.assertIn("/run/service/dashboard", control)
        self.assertIn("/opt/hermes/.venv/bin/python", wrapper)
        self.assertIn("Start Dashboard as the Hermes service account", wrapper)

    def test_default_is_disabled_and_renders_nothing(self):
        documents = render(False)
        self.assertFalse(any(
            doc["kind"] == "ConfigMap"
            and doc["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "paseo-host-adapter"
            for doc in documents
        ))
        deployment = next(doc for doc in documents if doc["kind"] == "Deployment" and doc["metadata"]["name"] == "adapter-test")
        pod = deployment["spec"]["template"]["spec"]
        self.assertFalse(any(volume["name"] == "hermes-paseo-host" for volume in pod["volumes"]))
        self.assertFalse(any(mount["name"] == "hermes-paseo-host" for mount in pod["containers"][0]["volumeMounts"]))

    def test_enabled_renders_immutable_reviewed_configmap_and_read_only_mounts(self):
        documents = render(True)
        configmap = next(
            doc for doc in documents
            if doc["kind"] == "ConfigMap"
            and doc["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "paseo-host-adapter"
        )
        self.assertTrue(configmap["immutable"])
        self.assertEqual(set(configmap["data"]), set(FILES))
        self.assertEqual(configmap["metadata"]["annotations"]["woowtech.io/source-commit"], "7b9c88d032672f688c88df222e384ce3bc1af2f2")
        for name, expected in FILES.items():
            self.assertEqual(hashlib.sha256(configmap["data"][name].encode()).hexdigest(), expected, name)
        deployment = next(doc for doc in documents if doc["kind"] == "Deployment" and doc["metadata"]["name"] == "adapter-test")
        pod = deployment["spec"]["template"]["spec"]
        volume = next(volume for volume in pod["volumes"] if volume["name"] == "hermes-paseo-host")
        self.assertEqual(volume["configMap"]["name"], configmap["metadata"]["name"])
        self.assertEqual(volume["configMap"]["defaultMode"], 0o555)
        self.assertEqual([item["key"] for item in volume["configMap"]["items"]], list(FILES))
        mounts = [mount for mount in pod["containers"][0]["volumeMounts"] if mount["name"] == "hermes-paseo-host"]
        self.assertEqual(mounts, [
            {"name": "hermes-paseo-host", "mountPath": "/opt/hermes-paseo-dashboard-control", "readOnly": True},
            {"name": "hermes-paseo-host", "mountPath": "/opt/hermes/.venv/bin/hermes", "subPath": "hermes", "readOnly": True},
        ])
        env = {item["name"]: item.get("value") for item in pod["containers"][0]["env"]}
        self.assertEqual(env["HERMES_DASHBOARD_PUBLIC_URL"], "https://example.invalid")
        rendered = yaml.safe_dump_all(documents)
        self.assertNotIn("plugins install", rendered)
        self.assertNotIn("plugins enable", rendered)

    def test_long_instance_names_retain_unique_instance_and_hash_suffix(self):
        shared = "a" * 61
        instances = [shared + "01", shared + "02"]
        names = []
        for instance in instances:
            documents = render(True, instance)
            configmap = next(
                doc for doc in documents
                if doc["kind"] == "ConfigMap"
                and doc["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "paseo-host-adapter"
            )
            name = configmap["metadata"]["name"]
            self.assertTrue(name.startswith(instance + "-paseo-host-"))
            suffix = name.rsplit("-", 1)[1]
            self.assertRegex(suffix, r"^[0-9a-f]{12}$")
            self.assertLessEqual(len(name), 253)
            deployment = next(doc for doc in documents if doc["kind"] == "Deployment" and doc["metadata"]["name"] == instance)
            volume = next(item for item in deployment["spec"]["template"]["spec"]["volumes"] if item["name"] == "hermes-paseo-host")
            self.assertEqual(volume["configMap"]["name"], name)
            names.append(name)
        self.assertNotEqual(names[0], names[1])
        self.assertEqual(names[0].rsplit("-", 1)[1], names[1].rsplit("-", 1)[1])

    def test_enabled_requires_a_clean_public_origin(self):
        command = [
            "helm", "template", "adapter-test", str(ROOT), "-n", "adapter-test",
            "--set", "instance=adapter-test,hermes.paseoHostAdapter.enabled=true",
            "--set-string", PH,
            "--set-string", "hermes.paseoHostAdapter.publicUrl=https://user@example.invalid/path",
        ]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be an http(s) origin", result.stderr)


if __name__ == "__main__":
    unittest.main()
