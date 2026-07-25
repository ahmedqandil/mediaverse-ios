from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SEMANTIC_KEYS = (
    "skin",
    "beard",
    "hair",
    "eyes",
    "brows",
    "lips",
    "teeth",
    "background",
)
CONTROL_KEYS = (
    "clear_skin",
    "wrinkles",
    "under_eye",
    "tone",
    "glow",
    "eyes",
    "teeth",
    "detail",
)


@dataclass(frozen=True)
class ManifestRecord:
    sample_id: str
    source: Path
    target: Path
    masks: dict[str, Path]
    controls: tuple[float, ...]
    split: str
    license_id: str
    consent_id: str


def _resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def parse_record(raw: dict, root: Path, line_number: int) -> ManifestRecord:
    required = ("id", "source", "target", "masks", "controls", "split", "rights")
    missing = [key for key in required if key not in raw]
    if missing:
        raise ValueError(f"line {line_number}: missing {', '.join(missing)}")

    masks_raw = raw["masks"]
    missing_masks = [key for key in SEMANTIC_KEYS if key not in masks_raw]
    if missing_masks:
        raise ValueError(f"line {line_number}: missing masks {', '.join(missing_masks)}")

    controls_raw = raw["controls"]
    missing_controls = [key for key in CONTROL_KEYS if key not in controls_raw]
    if missing_controls:
        raise ValueError(f"line {line_number}: missing controls {', '.join(missing_controls)}")
    controls = tuple(float(controls_raw[key]) for key in CONTROL_KEYS)
    if any(value < 0 or value > 1 for value in controls):
        raise ValueError(f"line {line_number}: controls must be within [0, 1]")

    rights = raw["rights"]
    license_id = str(rights.get("license_id", "")).strip()
    consent_id = str(rights.get("consent_id", "")).strip()
    commercial = rights.get("commercial_training")
    if not license_id or not consent_id or commercial is not True:
        raise ValueError(
            f"line {line_number}: explicit license, consent, and commercial_training=true are required"
        )

    return ManifestRecord(
        sample_id=str(raw["id"]),
        source=_resolve(root, str(raw["source"])),
        target=_resolve(root, str(raw["target"])),
        masks={key: _resolve(root, str(masks_raw[key])) for key in SEMANTIC_KEYS},
        controls=controls,
        split=str(raw["split"]),
        license_id=license_id,
        consent_id=consent_id,
    )


def read_manifest(path: Path, check_files: bool = True) -> list[ManifestRecord]:
    records: list[ManifestRecord] = []
    ids: set[str] = set()
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            record = parse_record(json.loads(line), path.parent, line_number)
            if record.sample_id in ids:
                raise ValueError(f"line {line_number}: duplicate id {record.sample_id}")
            ids.add(record.sample_id)
            if check_files:
                files: Iterable[Path] = (record.source, record.target, *record.masks.values())
                missing = [str(file) for file in files if not file.is_file()]
                if missing:
                    raise ValueError(f"line {line_number}: missing files: {', '.join(missing)}")
            records.append(record)
    if not records:
        raise ValueError("manifest contains no samples")
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate a Mediaverse Beauty JSONL manifest.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--skip-files", action="store_true")
    args = parser.parse_args()
    records = read_manifest(args.manifest, check_files=not args.skip_files)
    splits = sorted({record.split for record in records})
    print(f"valid: {len(records)} samples; splits={','.join(splits)}")


if __name__ == "__main__":
    main()

