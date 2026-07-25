"""Generate a deterministic, tiny research fixture for pipeline smoke training."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from .ffhqr import FFHQRPair, prepare_research_manifests


def generate(root: Path, size: int = 32) -> dict[str, Path]:
    pairs = []
    for sample_id in ("00000", "56000", "63000"):
        split = "train" if sample_id == "00000" else (
            "validation" if sample_id == "56000" else "test"
        )
        source = root / "images" / "source" / f"{sample_id}.png"
        target = root / "images" / "target" / f"{sample_id}.png"
        source.parent.mkdir(parents=True, exist_ok=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        y, x = np.mgrid[:size, :size]
        base = np.stack(
            ((x + int(sample_id)) % 256, (y * 3) % 256, ((x + y) * 2) % 256),
            axis=-1,
        ).astype(np.uint8)
        Image.fromarray(base, mode="RGB").save(source)
        polished = base.copy()
        polished[size // 4 : size * 3 // 4, size // 4 : size * 3 // 4] = np.clip(
            polished[size // 4 : size * 3 // 4, size // 4 : size * 3 // 4] + 4,
            0,
            255,
        )
        Image.fromarray(polished, mode="RGB").save(target)
        pairs.append(
            FFHQRPair(
                sample_id=sample_id,
                source=str(source.resolve()),
                target=str(target.resolve()),
                split=split,
            )
        )

    def fixture_skin(_: Path) -> np.ndarray:
        y, x = np.mgrid[:size, :size]
        return (((x - size / 2) ** 2 + (y - size / 2) ** 2) < (size / 3) ** 2).astype(
            np.float32
        )

    return prepare_research_manifests(pairs, root, fixture_skin)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, default=32)
    args = parser.parse_args()
    for split, path in generate(args.output, args.size).items():
        print(f"{split}: {path}")


if __name__ == "__main__":
    main()
