from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import torch
from torch import nn

from .model import BeautyEngine, BeautyEngineConfig
from .manifest import COMMERCIAL_SCOPE, RESEARCH_SCOPE


class ExportWrapper(nn.Module):
    def __init__(self, model: BeautyEngine) -> None:
        super().__init__()
        self.model = model

    def forward(
        self,
        image: torch.Tensor,
        semantic_masks: torch.Tensor,
        controls: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        return self.model(image, semantic_masks, controls)


def validate_export_scope(checkpoint: dict, allow_research_export: bool) -> dict[str, str]:
    metadata = checkpoint.get("artifact_metadata")
    if not isinstance(metadata, dict) or not metadata.get("usage_scope"):
        raise ValueError("refusing to export checkpoint without artifact usage metadata")
    scope = str(metadata["usage_scope"])
    if scope != COMMERCIAL_SCOPE and not (
        scope == RESEARCH_SCOPE and allow_research_export
    ):
        raise ValueError(
            "refusing to export noncommercial research checkpoint; "
            "pass --allow-research-export for an explicitly quarantined artifact"
        )
    return {
        "usage_scope": scope,
        "license_id": str(metadata.get("license_id", "")),
        "citation": str(metadata.get("citation", "")),
    }


def export(
    checkpoint_path: Path,
    destination: Path,
    minimum_ios: int,
    allow_research_export: bool = False,
) -> None:
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    artifact_metadata = validate_export_scope(checkpoint, allow_research_export)
    raw = checkpoint["config"]
    data = raw["data"]
    architecture = raw["model"]
    config = BeautyEngineConfig(
        semantic_channels=int(data["semantic_channels"]),
        control_count=int(architecture["control_count"]),
        base_channels=int(architecture["base_channels"]),
        residual_blocks=int(architecture["residual_blocks"]),
    )
    model = BeautyEngine(config)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    wrapper = ExportWrapper(model).eval()
    size = int(data["crop_size"])
    examples = (
        torch.zeros(1, 3, size, size),
        torch.zeros(1, config.semantic_channels, size, size),
        torch.zeros(1, config.control_count),
    )
    traced = torch.jit.trace(wrapper, examples)
    target = getattr(ct.target, f"iOS{minimum_ios}")
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=target,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(name="image", shape=examples[0].shape),
            ct.TensorType(name="semantic_masks", shape=examples[1].shape),
            ct.TensorType(name="controls", shape=examples[2].shape),
        ],
        outputs=[
            ct.TensorType(name="residual"),
            ct.TensorType(name="confidence"),
            ct.TensorType(name="refined_skin_mask"),
            ct.TensorType(name="detail"),
        ],
    )
    converted.author = "Mediaverse"
    converted.short_description = "Mediaverse-owned residual face-retouching engine"
    converted.version = str(raw["experiment"])
    converted.user_defined_metadata["mediaverse.config"] = json.dumps(raw, sort_keys=True)
    converted.user_defined_metadata["mediaverse.usage_scope"] = artifact_metadata["usage_scope"]
    converted.user_defined_metadata["mediaverse.license_id"] = artifact_metadata["license_id"]
    converted.user_defined_metadata["mediaverse.citation"] = artifact_metadata["citation"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    converted.save(destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--minimum-ios", type=int, default=17)
    parser.add_argument(
        "--allow-research-export",
        action="store_true",
        help="Export a labeled research artifact that the iOS runtime will reject.",
    )
    args = parser.parse_args()
    export(
        args.checkpoint,
        args.output,
        args.minimum_ios,
        allow_research_export=args.allow_research_export,
    )


if __name__ == "__main__":
    main()
