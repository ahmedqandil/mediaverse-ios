from __future__ import annotations

import argparse
from pathlib import Path

import torch
import yaml
from torch.utils.data import DataLoader

from .dataset import BeautyDataset
from .losses import charbonnier
from .model import BeautyEngine, BeautyEngineConfig
from .train import choose_device, save_checkpoint


def model_from_checkpoint(path: Path, device: torch.device) -> tuple[BeautyEngine, dict]:
    checkpoint = torch.load(path, map_location=device, weights_only=False)
    raw = checkpoint["config"]
    model = BeautyEngine(
        BeautyEngineConfig(
            semantic_channels=int(raw["data"]["semantic_channels"]),
            control_count=int(raw["model"]["control_count"]),
            base_channels=int(raw["model"]["base_channels"]),
            residual_blocks=int(raw["model"]["residual_blocks"]),
        )
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    return model, raw


def run(teacher_path: Path, student_config_path: Path) -> None:
    device = choose_device()
    teacher, teacher_config = model_from_checkpoint(teacher_path, device)
    teacher.eval()
    config = yaml.safe_load(student_config_path.read_text(encoding="utf-8"))
    teacher_scope = str(teacher_config.get("usage_scope", "commercial"))
    student_scope = str(config.get("usage_scope", "commercial"))
    if teacher_scope != student_scope:
        raise ValueError(
            f"refusing cross-scope distillation: teacher={teacher_scope}, "
            f"student={student_scope}"
        )
    student = BeautyEngine(
        BeautyEngineConfig(
            semantic_channels=int(config["data"]["semantic_channels"]),
            control_count=int(config["model"]["control_count"]),
            base_channels=int(config["model"]["base_channels"]),
            residual_blocks=int(config["model"]["residual_blocks"]),
        )
    ).to(device)
    dataset = BeautyDataset(
        config["data"]["train_manifest"],
        crop_size=int(config["data"]["crop_size"]),
        augment=True,
        manifest_mode=str(config["data"].get("manifest_mode", "commercial")),
    )
    loader = DataLoader(
        dataset,
        batch_size=int(config["training"]["batch_size"]),
        shuffle=True,
        num_workers=int(config["training"]["num_workers"]),
    )
    optimizer = torch.optim.AdamW(
        student.parameters(),
        lr=float(config["training"]["learning_rate"]),
        weight_decay=float(config["training"]["weight_decay"]),
    )
    checkpoint_dir = Path(config["training"]["checkpoint_dir"])
    for epoch in range(1, int(config["training"]["epochs"]) + 1):
        student.train()
        for batch in loader:
            source = batch["source"].to(device)
            masks = batch["masks"].to(device)
            controls = batch["controls"].to(device)
            with torch.inference_mode():
                teacher_outputs = teacher(source, masks, controls)
            student_outputs = student(source, masks, controls)
            loss = sum(
                charbonnier(student_value - teacher_value)
                for student_value, teacher_value in zip(student_outputs, teacher_outputs)
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            optimizer.step()
        save_checkpoint(checkpoint_dir / "distilled-latest.pt", student, optimizer, epoch, config)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teacher", type=Path, required=True)
    parser.add_argument("--student-config", type=Path, required=True)
    args = parser.parse_args()
    run(args.teacher, args.student_config)


if __name__ == "__main__":
    main()
