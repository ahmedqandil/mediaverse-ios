from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def load_mask(path: Path, size: tuple[int, int]) -> np.ndarray:
    image = Image.open(path).convert("L").resize(size, Image.Resampling.BILINEAR)
    return np.asarray(image, dtype=np.float32)[:, :, None] / 255.0


def metrics(source: np.ndarray, target: np.ndarray, output: np.ndarray, skin: np.ndarray) -> dict:
    if source.shape != target.shape or source.shape != output.shape:
        raise ValueError("source, target, and output dimensions must match")
    error = output - target
    mse = float(np.mean(error * error))
    psnr = float("inf") if mse == 0 else 10 * math.log10(1 / mse)
    outside = 1 - skin
    outside_denominator = max(float(outside.sum()) * 3, 1)
    background_mae = float((np.abs(output - source) * outside).sum() / outside_denominator)
    changed = np.max(np.abs(output - source), axis=2) > (2 / 255)
    changed_fraction = float(changed.mean())
    return {
        "psnr_target_db": psnr,
        "background_mae": background_mae,
        "changed_pixel_fraction": changed_fraction,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate one golden Beauty output.")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skin-mask", type=Path, required=True)
    args = parser.parse_args()
    source = load_rgb(args.source)
    target = load_rgb(args.target)
    output = load_rgb(args.output)
    skin = load_mask(args.skin_mask, (source.shape[1], source.shape[0]))
    print(json.dumps(metrics(source, target, output, skin), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

