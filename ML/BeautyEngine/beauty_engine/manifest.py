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
COMMERCIAL_SCOPE = "commercial"
RESEARCH_SCOPE = "research_noncommercial"
USAGE_SCOPES = (COMMERCIAL_SCOPE, RESEARCH_SCOPE)


@dataclass(frozen=True)
class ManifestRecord:
    sample_id: str
    subject_id: str
    source: Path
    target: Path
    masks: dict[str, Path]
    controls: tuple[float, ...]
    split: str
    license_id: str
    consent_id: str
    usage_scope: str
    citation: str


def _resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def parse_record(
    raw: dict,
    root: Path,
    line_number: int,
    manifest_mode: str = COMMERCIAL_SCOPE,
) -> ManifestRecord:
    if manifest_mode not in USAGE_SCOPES:
        raise ValueError(f"unsupported manifest mode: {manifest_mode}")
    required = ("id", "subject_id", "source", "target", "masks", "controls", "split", "rights")
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
    usage_scope = str(rights.get("usage_scope", COMMERCIAL_SCOPE)).strip()
    citation = str(rights.get("citation", "")).strip()
    if usage_scope != manifest_mode:
        raise ValueError(
            f"line {line_number}: usage_scope={usage_scope!r} does not match "
            f"manifest mode {manifest_mode!r}"
        )
    if manifest_mode == COMMERCIAL_SCOPE and (
        not license_id or not consent_id or commercial is not True
    ):
        raise ValueError(
            f"line {line_number}: explicit license, consent, and commercial_training=true are required"
        )
    if manifest_mode == RESEARCH_SCOPE and (
        not license_id or commercial is not False or not citation
    ):
        raise ValueError(
            f"line {line_number}: research manifests require license, citation, "
            "and commercial_training=false"
        )

    return ManifestRecord(
        sample_id=str(raw["id"]),
        subject_id=str(raw["subject_id"]),
        source=_resolve(root, str(raw["source"])),
        target=_resolve(root, str(raw["target"])),
        masks={key: _resolve(root, str(masks_raw[key])) for key in SEMANTIC_KEYS},
        controls=controls,
        split=str(raw["split"]),
        license_id=license_id,
        consent_id=consent_id,
        usage_scope=usage_scope,
        citation=citation,
    )


def read_manifest(
    path: Path,
    check_files: bool = True,
    manifest_mode: str = COMMERCIAL_SCOPE,
) -> list[ManifestRecord]:
    records: list[ManifestRecord] = []
    ids: set[str] = set()
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            record = parse_record(
                json.loads(line), path.parent, line_number, manifest_mode=manifest_mode
            )
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


def audit_identity_splits(
    manifests: list[Path],
    check_files: bool = True,
    manifest_mode: str = COMMERCIAL_SCOPE,
) -> dict:
    subjects_by_split: dict[str, set[str]] = {}
    licenses: set[str] = set()
    consent_ids: set[str] = set()
    sample_count = 0
    for manifest in manifests:
        for record in read_manifest(
            manifest, check_files=check_files, manifest_mode=manifest_mode
        ):
            subjects_by_split.setdefault(record.split, set()).add(record.subject_id)
            licenses.add(record.license_id)
            consent_ids.add(record.consent_id)
            sample_count += 1

    splits = sorted(subjects_by_split)
    overlaps: list[str] = []
    for index, first in enumerate(splits):
        for second in splits[index + 1 :]:
            shared = subjects_by_split[first] & subjects_by_split[second]
            if shared:
                overlaps.append(f"{first}/{second}: {','.join(sorted(shared))}")
    if overlaps:
        raise ValueError("subject leakage across splits: " + "; ".join(overlaps))
    return {
        "samples": sample_count,
        "subjects": sum(len(values) for values in subjects_by_split.values()),
        "splits": {key: len(value) for key, value in sorted(subjects_by_split.items())},
        "licenses": sorted(licenses),
        "consents": len(consent_ids),
        "usage_scope": manifest_mode,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate a Mediaverse Beauty JSONL manifest.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--additional", type=Path, nargs="*", default=[])
    parser.add_argument("--skip-files", action="store_true")
    parser.add_argument("--mode", choices=USAGE_SCOPES, default=COMMERCIAL_SCOPE)
    args = parser.parse_args()
    report = audit_identity_splits(
        [args.manifest, *args.additional],
        check_files=not args.skip_files,
        manifest_mode=args.mode,
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
