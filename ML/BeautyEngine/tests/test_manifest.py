from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from beauty_engine.manifest import CONTROL_KEYS, SEMANTIC_KEYS, parse_record, read_manifest


def valid_record() -> dict:
    return {
        "id": "sample-1",
        "source": "source.png",
        "target": "target.png",
        "masks": {key: f"{key}.png" for key in SEMANTIC_KEYS},
        "controls": {key: 0.5 for key in CONTROL_KEYS},
        "split": "train",
        "rights": {
            "license_id": "license-1",
            "consent_id": "consent-1",
            "commercial_training": True,
        },
    }


class ManifestTests(unittest.TestCase):
    def test_valid_record_preserves_control_order(self) -> None:
        record = parse_record(valid_record(), Path("/dataset"), 1)
        self.assertEqual(record.controls, tuple(0.5 for _ in CONTROL_KEYS))
        self.assertEqual(record.source, Path("/dataset/source.png"))

    def test_rejects_noncommercial_record(self) -> None:
        raw = valid_record()
        raw["rights"]["commercial_training"] = False
        with self.assertRaisesRegex(ValueError, "commercial_training"):
            parse_record(raw, Path("."), 1)

    def test_rejects_out_of_range_control(self) -> None:
        raw = valid_record()
        raw["controls"]["wrinkles"] = 1.1
        with self.assertRaisesRegex(ValueError, r"within \[0, 1\]"):
            parse_record(raw, Path("."), 1)

    def test_rejects_duplicate_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.jsonl"
            raw = json.dumps(valid_record())
            path.write_text(f"{raw}\n{raw}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate id"):
                read_manifest(path, check_files=False)


if __name__ == "__main__":
    unittest.main()

