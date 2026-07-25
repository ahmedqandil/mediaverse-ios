"""FFHQR research indexing with a hard commercial-training boundary."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image

from .manifest import CONTROL_KEYS, RESEARCH_SCOPE, SEMANTIC_KEYS

FFHQR_LICENSE = "CC-BY-NC-SA-4.0"
FFHQR_CITATION = "Shafaei, Little, and Schmidt, AutoRetouch, WACV 2021"
RESEARCH_USE = RESEARCH_SCOPE


@dataclass(frozen=True)
class FFHQRPair:
    sample_id: str
    source: str
    target: str
    split: str
    intended_use: str = RESEARCH_USE
    license_id: str = FFHQR_LICENSE
    citation: str = FFHQR_CITATION
    commercial_training: bool = False


def split_for_sample(sample_id: str) -> str:
    """Return the official FFHQR folder split for a five-digit sample id."""
    try:
        index = int(sample_id)
    except ValueError as error:
        raise ValueError(f"invalid FFHQR sample id: {sample_id}") from error
    if not 0 <= index <= 69_999:
        raise ValueError(f"FFHQR sample id outside 00000-69999: {sample_id}")
    if index < 56_000:
        return "train"
    if index < 63_000:
        return "validation"
    return "test"


def _pngs_by_id(root: Path) -> dict[str, Path]:
    if not root.is_dir():
        raise ValueError(f"image root is not a directory: {root}")
    result: dict[str, Path] = {}
    for path in sorted(root.rglob("*.png")):
        sample_id = path.stem
        if not sample_id.isdigit():
            continue
        if sample_id in result:
            raise ValueError(f"duplicate FFHQR sample id {sample_id} under {root}")
        result[sample_id] = path
    return result


def index_pairs(source_root: Path, target_root: Path, strict: bool = True) -> list[FFHQRPair]:
    """Match original FFHQ and retouched FFHQR PNGs without copying image data."""
    sources = _pngs_by_id(source_root)
    targets = _pngs_by_id(target_root)
    source_only = sorted(sources.keys() - targets.keys())
    target_only = sorted(targets.keys() - sources.keys())
    if strict and (source_only or target_only):
        details = []
        if source_only:
            details.append(f"{len(source_only)} source-only")
        if target_only:
            details.append(f"{len(target_only)} target-only")
        raise ValueError("unpaired FFHQR files: " + ", ".join(details))

    pairs = []
    for sample_id in sorted(sources.keys() & targets.keys(), key=int):
        pairs.append(
            FFHQRPair(
                sample_id=sample_id.zfill(5),
                source=str(sources[sample_id].resolve()),
                target=str(targets[sample_id].resolve()),
                split=split_for_sample(sample_id),
            )
        )
    if not pairs:
        raise ValueError("no paired FFHQ/FFHQR PNG files found")
    return pairs


def write_index(pairs: list[FFHQRPair], output: Path) -> dict:
    """Write a research-only index; this is intentionally not a training manifest."""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "".join(json.dumps(asdict(pair), sort_keys=True) + "\n" for pair in pairs),
        encoding="utf-8",
    )
    splits: dict[str, int] = {}
    for pair in pairs:
        splits[pair.split] = splits.get(pair.split, 0) + 1
    return {
        "samples": len(pairs),
        "splits": dict(sorted(splits.items())),
        "intended_use": RESEARCH_USE,
        "license_id": FFHQR_LICENSE,
        "commercial_training": False,
        "output": str(output),
    }


def load_face_parser(model_path: Path) -> Callable[[Path], np.ndarray]:
    """Load the bundled Core ML parser and return a source-image-only predictor."""
    import coremltools as ct

    model = ct.models.MLModel(str(model_path))

    def predict(source: Path) -> np.ndarray:
        image = Image.open(source).convert("RGB").resize((512, 512), Image.Resampling.LANCZOS)
        result = model.predict({"image": image})
        mask = np.asarray(result["skin_mask"], dtype=np.float32).squeeze()
        if mask.shape != (512, 512):
            raise ValueError(f"unexpected FaceParser output shape: {mask.shape}")
        return np.clip(mask, 0, 1)

    return predict


def _save_mask(mask: np.ndarray, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.rint(np.clip(mask, 0, 1) * 255).astype(np.uint8), mode="L").save(path)


def prepare_research_manifests(
    pairs: list[FFHQRPair],
    output_root: Path,
    skin_predictor: Callable[[Path], np.ndarray],
) -> dict[str, Path]:
    """Create research training manifests and source-derived semantic masks.

    FaceParser currently exposes skin only. Unsupported feature channels are zeros;
    background is conservatively the inverse of skin. No target pixels are passed to
    the predictor or used to derive masks.
    """
    manifest_handles = {}
    manifest_paths = {
        split: output_root / "manifests" / f"{split}.jsonl"
        for split in ("train", "validation", "test")
    }
    try:
        for split, path in manifest_paths.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            manifest_handles[split] = path.open("w", encoding="utf-8")
        for pair in pairs:
            source = Path(pair.source)
            skin = skin_predictor(source)
            if skin.ndim != 2:
                raise ValueError(f"skin predictor must return HxW, got {skin.shape}")
            zeros = np.zeros_like(skin)
            masks = {key: zeros for key in SEMANTIC_KEYS}
            masks["skin"] = skin
            masks["background"] = 1 - skin
            mask_paths = {}
            for key in SEMANTIC_KEYS:
                path = output_root / "masks" / pair.sample_id / f"{key}.png"
                _save_mask(masks[key], path)
                mask_paths[key] = str(path.resolve())
            controls = {key: 0.0 for key in CONTROL_KEYS}
            controls.update(
                {
                    "clear_skin": 1.0,
                    "wrinkles": 1.0,
                    "under_eye": 1.0,
                    "detail": 1.0,
                }
            )
            record = {
                "id": f"ffhqr-{pair.sample_id}",
                "subject_id": f"ffhqr-{pair.sample_id}",
                "source": pair.source,
                "target": pair.target,
                "masks": mask_paths,
                "controls": controls,
                "split": pair.split,
                "rights": {
                    "usage_scope": RESEARCH_SCOPE,
                    "license_id": FFHQR_LICENSE,
                    "consent_id": "",
                    "citation": FFHQR_CITATION,
                    "commercial_training": False,
                },
            }
            manifest_handles[pair.split].write(json.dumps(record, sort_keys=True) + "\n")
    finally:
        for handle in manifest_handles.values():
            handle.close()
    return manifest_paths


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a research-only index from local FFHQ and FFHQR images."
    )
    parser.add_argument("--ffhq-root", type=Path, required=True)
    parser.add_argument("--ffhqr-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--prepare-training",
        action="store_true",
        help="Create quarantined research manifests and source-derived masks.",
    )
    parser.add_argument(
        "--face-parser",
        type=Path,
        default=Path("../../Mediaverse-Swift/Resources/ML/FaceParser.mlpackage"),
    )
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Index the intersection instead of rejecting unpaired files.",
    )
    args = parser.parse_args()
    pairs = index_pairs(args.ffhq_root, args.ffhqr_root, strict=not args.allow_incomplete)
    report = write_index(pairs, args.output)
    if args.prepare_training:
        paths = prepare_research_manifests(
            pairs,
            args.output.parent,
            load_face_parser(args.face_parser),
        )
        report["manifests"] = {key: str(value) for key, value in paths.items()}
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
