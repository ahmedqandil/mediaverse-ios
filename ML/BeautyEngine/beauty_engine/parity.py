from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from .export_coreml import ExportWrapper
from .model import BeautyEngine, BeautyEngineConfig


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tolerance", type=float, default=0.003)
    args = parser.parse_args()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    raw = checkpoint["config"]
    config = BeautyEngineConfig(
        semantic_channels=int(raw["data"]["semantic_channels"]),
        control_count=int(raw["model"]["control_count"]),
        base_channels=int(raw["model"]["base_channels"]),
        residual_blocks=int(raw["model"]["residual_blocks"]),
    )
    model = BeautyEngine(config).eval()
    model.load_state_dict(checkpoint["model"])
    size = int(raw["data"]["crop_size"])
    generator = torch.Generator().manual_seed(20260725)
    image = torch.rand(1, 3, size, size, generator=generator)
    masks = torch.rand(1, config.semantic_channels, size, size, generator=generator)
    controls = torch.rand(1, config.control_count, generator=generator)
    with torch.inference_mode():
        expected = ExportWrapper(model).eval()(image, masks, controls)
    # coremltools currently accepts strings here more reliably than pathlib.Path.
    actual = ct.models.MLModel(str(args.model)).predict(
        {
            "image": image.numpy(),
            "semantic_masks": masks.numpy(),
            "controls": controls.numpy(),
        }
    )
    names = ("residual", "confidence", "refined_skin_mask", "detail")
    deltas = {
        name: float(np.max(np.abs(actual[name] - tensor.numpy())))
        for name, tensor in zip(names, expected)
    }
    print(json.dumps(deltas, indent=2, sort_keys=True))
    if max(deltas.values()) > args.tolerance:
        raise SystemExit(f"Core ML parity failed: tolerance={args.tolerance}")


if __name__ == "__main__":
    main()
