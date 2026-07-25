from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np
import torch
import yaml
from torch.utils.data import DataLoader

from .dataset import BeautyDataset
from .losses import BeautyLoss
from .model import BeautyEngine, BeautyEngineConfig


def choose_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def save_checkpoint(
    path: Path,
    model: BeautyEngine,
    optimizer: torch.optim.Optimizer,
    epoch: int,
    config: dict,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "epoch": epoch,
            "model": model.state_dict(),
            "optimizer": optimizer.state_dict(),
            "config": config,
        },
        path,
    )


def run(config_path: Path) -> None:
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    seed = int(config["seed"])
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    device = choose_device()

    data_config = config["data"]
    train_data = BeautyDataset(
        data_config["train_manifest"],
        crop_size=int(data_config["crop_size"]),
        augment=True,
    )
    validation_data = BeautyDataset(
        data_config["validation_manifest"],
        crop_size=int(data_config["crop_size"]),
        augment=False,
    )
    training = config["training"]
    train_loader = DataLoader(
        train_data,
        batch_size=int(training["batch_size"]),
        shuffle=True,
        num_workers=int(training["num_workers"]),
        pin_memory=device.type == "cuda",
    )
    validation_loader = DataLoader(validation_data, batch_size=1, shuffle=False)

    model_config = BeautyEngineConfig(
        semantic_channels=int(data_config["semantic_channels"]),
        control_count=int(config["model"]["control_count"]),
        base_channels=int(config["model"]["base_channels"]),
        residual_blocks=int(config["model"]["residual_blocks"]),
    )
    model = BeautyEngine(model_config).to(device)
    loss_function = BeautyLoss(config["loss"])
    optimizer = torch.optim.AdamW(
        model.parameters(),
        lr=float(training["learning_rate"]),
        weight_decay=float(training["weight_decay"]),
    )
    checkpoint_dir = Path(training["checkpoint_dir"])
    best_validation = float("inf")

    for epoch in range(1, int(training["epochs"]) + 1):
        model.train()
        training_total = 0.0
        for batch in train_loader:
            source = batch["source"].to(device)
            target = batch["target"].to(device)
            masks = batch["masks"].to(device)
            controls = batch["controls"].to(device)
            residual, confidence, refined_skin, detail = model(source, masks, controls)
            output = model.composite(
                source, residual, confidence, refined_skin, detail, controls[:, 0]
            )
            loss, _ = loss_function(
                source, target, output, confidence, refined_skin, masks[:, :1]
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            training_total += float(loss.detach())

        model.eval()
        validation_total = 0.0
        with torch.inference_mode():
            for batch in validation_loader:
                source = batch["source"].to(device)
                target = batch["target"].to(device)
                masks = batch["masks"].to(device)
                controls = batch["controls"].to(device)
                residual, confidence, refined_skin, detail = model(source, masks, controls)
                output = model.composite(
                    source, residual, confidence, refined_skin, detail, controls[:, 0]
                )
                loss, _ = loss_function(
                    source, target, output, confidence, refined_skin, masks[:, :1]
                )
                validation_total += float(loss)

        metrics = {
            "epoch": epoch,
            "train_loss": training_total / max(len(train_loader), 1),
            "validation_loss": validation_total / max(len(validation_loader), 1),
            "device": str(device),
        }
        print(json.dumps(metrics, sort_keys=True))
        save_checkpoint(checkpoint_dir / "latest.pt", model, optimizer, epoch, config)
        if metrics["validation_loss"] < best_validation:
            best_validation = metrics["validation_loss"]
            save_checkpoint(checkpoint_dir / "best.pt", model, optimizer, epoch, config)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    run(args.config)


if __name__ == "__main__":
    main()

