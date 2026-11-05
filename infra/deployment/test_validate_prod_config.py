"""Offline security regression checks for the production Compose template."""

from copy import deepcopy
import hashlib
from pathlib import Path
import tempfile
import unittest

import validate_prod_config as target


class ProductionConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = target.render_compose(sample=True)

    def test_template_is_valid_with_unusable_sample_values(self):
        target.validate_config(self.config, sample=True)

    def test_restore_template_is_private_and_isolated(self):
        target.validate_restore_config(target.render_restore_sample())

    def test_volume_names_cannot_be_repointed_to_existing_projects(self):
        config = deepcopy(self.config)
        config["volumes"]["postgres_data"]["name"] = "gomove_m572_postgres_data"
        with self.assertRaisesRegex(target.PreflightError, "volume name"):
            target.validate_config(config, sample=True)
        restore = target.render_restore_sample()
        restore["volumes"]["restore_data"]["name"] = "gomove-m573-postgres-data"
        with self.assertRaisesRegex(target.PreflightError, "data volume"):
            target.validate_restore_config(restore)

    def test_only_caddy_publishes_host_ports(self):
        config = deepcopy(self.config)
        config["services"]["postgres"]["ports"] = [{"published": "5432", "target": 5432, "protocol": "tcp"}]
        with self.assertRaisesRegex(target.PreflightError, "host port"):
            target.validate_config(config, sample=True)

    def test_rejects_mutable_image_tag(self):
        config = deepcopy(self.config)
        config["services"]["backend"]["image"] = "gomove-backend:latest"
        with self.assertRaisesRegex(target.PreflightError, "digest"):
            target.validate_config(config, sample=True)

    def test_rejects_dev_profile_and_secret_environment(self):
        for key, value in (("SPRING_PROFILES_ACTIVE", "dev"), ("JWT_SECRET", "fake")):
            with self.subTest(key=key):
                config = deepcopy(self.config)
                config["services"]["backend"]["environment"][key] = value
                with self.assertRaises(target.PreflightError):
                    target.validate_config(config, sample=True)

    def test_rejects_wildcard_hostname_and_internal_egress(self):
        config = deepcopy(self.config)
        config["services"]["caddy"]["environment"]["M573_PUBLIC_HOSTNAME"] = "*"
        with self.assertRaisesRegex(target.PreflightError, "hostname"):
            target.validate_config(config, sample=True)
        config = deepcopy(self.config)
        config["networks"]["edge"]["internal"] = True
        with self.assertRaisesRegex(target.PreflightError, "geocoding"):
            target.validate_config(config, sample=True)

    def test_empty_digest_or_missing_required_variable_fails(self):
        config = deepcopy(self.config)
        with self.assertRaisesRegex(target.PreflightError, "nonzero"):
            target.validate_config(config, sample=False)

    def test_password_copies_must_match_and_missing_secrets_fail(self):
        config = deepcopy(self.config)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            paths = {
                "db_password_backend": directory / "backend.txt",
                "db_password_postgres": directory / "postgres.txt",
                "jwt_secret": directory / "jwt.txt",
            }
            for name, path in paths.items():
                path.write_text("x" * 48 if name != "db_password_postgres" else "y" * 48)
                config["secrets"][name]["file"] = str(path)
            with self.assertRaisesRegex(target.PreflightError, "copies differ"):
                target.validate_secret_files(config)
            paths["db_password_postgres"].write_text("x" * 48)
            target.validate_secret_files(config)
            paths["jwt_secret"].unlink()
            with self.assertRaisesRegex(target.PreflightError, "existing file"):
                target.validate_secret_files(config)

    def test_dataset_requires_matching_checksums_and_complete_mld_set(self):
        config = deepcopy(self.config)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            files = {
                "hanoi.osrm.partition": b"partition",
                "hanoi.osrm.cells": b"cells",
                "hanoi.osrm.mldgr": b"mldgr",
            }
            for name, content in files.items():
                (directory / name).write_bytes(content)
            manifest = directory / "approved.sha256"
            manifest.write_text("".join(
                f"{hashlib.sha256(content).hexdigest()}  {name}\n"
                for name, content in files.items()
            ))
            config["services"]["osrm"]["volumes"][0]["source"] = str(directory)
            target.validate_dataset(config, manifest)
            (directory / "hanoi.osrm.cells").write_bytes(b"changed")
            with self.assertRaisesRegex(target.PreflightError, "checksum mismatch"):
                target.validate_dataset(config, manifest)


if __name__ == "__main__":
    unittest.main()
