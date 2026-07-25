from __future__ import annotations

import json
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from pathlib import Path

import numpy as np
import torch

from beauty_engine.export_coreml import validate_export_scope
from beauty_engine.ffhqr import (
    FFHQRPair,
    FFHQR_LICENSE,
    RESEARCH_USE,
    index_pairs,
    load_face_parser,
    prepare_research_manifests,
    split_for_sample,
    write_index,
)
from beauty_engine.manifest import RESEARCH_SCOPE, parse_record, read_manifest
from beauty_engine.model import BeautyEngine, BeautyEngineConfig
from beauty_engine.release_gate import check_checkpoint_scope
from beauty_engine.train import save_checkpoint


class FFHQRTests(unittest.TestCase):
    def test_face_parser_passes_coreml_a_string_path(self) -> None:
        fake_model = MagicMock()
        with patch("coremltools.models.MLModel", return_value=fake_model) as constructor:
            load_face_parser(Path("/models/FaceParser.mlpackage"))
        constructor.assert_called_once_with("/models/FaceParser.mlpackage")

    def test_uses_official_folder_splits(self) -> None:
        self.assertEqual(split_for_sample("00000"), "train")
        self.assertEqual(split_for_sample("55999"), "train")
        self.assertEqual(split_for_sample("56000"), "validation")
        self.assertEqual(split_for_sample("62999"), "validation")
        self.assertEqual(split_for_sample("63000"), "test")
        self.assertEqual(split_for_sample("69999"), "test")

    def test_rejects_unpaired_files_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            target = root / "target"
            source.mkdir()
            target.mkdir()
            (source / "00000.png").touch()
            with self.assertRaisesRegex(ValueError, "source-only"):
                index_pairs(source, target)

    def test_index_is_explicitly_noncommercial(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            target = root / "target"
            source.mkdir()
            target.mkdir()
            (source / "63000.png").touch()
            (target / "63000.png").touch()
            output = root / "index.jsonl"

            report = write_index(index_pairs(source, target), output)
            record = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(record["intended_use"], RESEARCH_USE)
            self.assertEqual(record["license_id"], FFHQR_LICENSE)
            self.assertFalse(record["commercial_training"])
            self.assertEqual(record["split"], "test")
            self.assertFalse(report["commercial_training"])

    def test_research_record_cannot_parse_as_training_manifest(self) -> None:
        raw = {
            "id": "63000",
            "subject_id": "ffhqr-63000",
            "source": "source.png",
            "target": "target.png",
            "masks": {},
            "controls": {},
            "split": "test",
            "rights": {
                "license_id": FFHQR_LICENSE,
                "consent_id": "not-provided",
                "commercial_training": False,
            },
        }
        with self.assertRaises(ValueError):
            parse_record(raw, Path("."), 1)

    def test_prepared_manifest_ingests_only_in_research_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source" / "63000.png"
            target = root / "target" / "63000.png"
            source.parent.mkdir()
            target.parent.mkdir()
            source.touch()
            target.touch()
            seen = []

            def predictor(path: Path) -> np.ndarray:
                seen.append(path)
                return np.ones((8, 8), dtype=np.float32)

            manifests = prepare_research_manifests(
                [
                    FFHQRPair("63000", str(source), str(target), "test")
                ],
                root / "prepared",
                predictor,
            )
            self.assertEqual(seen, [source])
            with self.assertRaisesRegex(ValueError, "usage_scope"):
                read_manifest(manifests["test"], check_files=False)
            records = read_manifest(
                manifests["test"],
                check_files=True,
                manifest_mode=RESEARCH_SCOPE,
            )
            self.assertEqual(records[0].usage_scope, RESEARCH_SCOPE)
            self.assertEqual(records[0].target, target)

    def test_checkpoint_metadata_and_export_quarantine(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint_path = Path(directory) / "research.pt"
            model = BeautyEngine(
                BeautyEngineConfig(
                    semantic_channels=8,
                    control_count=8,
                    base_channels=8,
                    residual_blocks=1,
                )
            )
            optimizer = torch.optim.AdamW(model.parameters())
            config = {
                "experiment": "test",
                "usage_scope": RESEARCH_SCOPE,
                "license_id": FFHQR_LICENSE,
                "citation": "AutoRetouch, WACV 2021",
            }
            save_checkpoint(checkpoint_path, model, optimizer, 1, config)
            checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
            self.assertEqual(
                checkpoint["artifact_metadata"]["usage_scope"], RESEARCH_SCOPE
            )
            with self.assertRaisesRegex(ValueError, "refusing to export"):
                validate_export_scope(checkpoint, allow_research_export=False)
            metadata = validate_export_scope(checkpoint, allow_research_export=True)
            self.assertEqual(metadata["license_id"], FFHQR_LICENSE)
            self.assertIn("not commercial", check_checkpoint_scope(checkpoint)[0])

    def test_resume_checkpoint_rejects_scope_mismatch(self) -> None:
        commercial = {"artifact_metadata": {"usage_scope": "commercial"}}
        self.assertEqual(check_checkpoint_scope(commercial), [])


if __name__ == "__main__":
    unittest.main()
