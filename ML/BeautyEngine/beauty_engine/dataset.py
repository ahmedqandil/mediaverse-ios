from __future__ import annotations

import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

from .manifest import ManifestRecord, SEMANTIC_KEYS, read_manifest


def _rgb(path: Path, size: int) -> torch.Tensor:
    image = Image.open(path).convert("RGB").resize((size, size), Image.Resampling.LANCZOS)
    array = np.asarray(image, dtype=np.float32) / 255.0
    return torch.from_numpy(array).permute(2, 0, 1)


def _mask(path: Path, size: int) -> torch.Tensor:
    image = Image.open(path).convert("L").resize((size, size), Image.Resampling.BILINEAR)
    array = np.asarray(image, dtype=np.float32) / 255.0
    return torch.from_numpy(array).unsqueeze(0)


class BeautyDataset(Dataset):
    def __init__(self, manifest: str | Path, crop_size: int, augment: bool) -> None:
        self.records: list[ManifestRecord] = read_manifest(Path(manifest))
        self.crop_size = crop_size
        self.augment = augment

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor | str]:
        record = self.records[index]
        source = _rgb(record.source, self.crop_size)
        target = _rgb(record.target, self.crop_size)
        masks = torch.cat(
            [_mask(record.masks[key], self.crop_size) for key in SEMANTIC_KEYS],
            dim=0,
        )
        if self.augment and random.random() < 0.5:
            source = torch.flip(source, dims=(2,))
            target = torch.flip(target, dims=(2,))
            masks = torch.flip(masks, dims=(2,))
        return {
            "id": record.sample_id,
            "source": source,
            "target": target,
            "masks": masks,
            "controls": torch.tensor(record.controls, dtype=torch.float32),
        }

