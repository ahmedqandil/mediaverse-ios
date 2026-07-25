from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import nn
from torch.nn import functional as F


@dataclass(frozen=True)
class BeautyEngineConfig:
    semantic_channels: int = 8
    control_count: int = 8
    base_channels: int = 32
    residual_blocks: int = 6


class ConvBlock(nn.Module):
    def __init__(self, input_channels: int, output_channels: int, stride: int = 1) -> None:
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv2d(input_channels, output_channels, 3, stride, 1, bias=False),
            nn.GroupNorm(min(8, output_channels), output_channels),
            nn.SiLU(inplace=True),
        )

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        return self.layers(value)


class MobileResidualBlock(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv2d(channels, channels, 3, 1, 1, groups=channels, bias=False),
            nn.GroupNorm(min(8, channels), channels),
            nn.SiLU(inplace=True),
            nn.Conv2d(channels, channels, 1, bias=False),
            nn.GroupNorm(min(8, channels), channels),
        )

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        return F.silu(value + self.layers(value))


class BeautyEngine(nn.Module):
    """Predicts bounded corrections; it never regenerates the complete image."""

    def __init__(self, config: BeautyEngineConfig) -> None:
        super().__init__()
        self.config = config
        inputs = 3 + config.semantic_channels + config.control_count
        c = config.base_channels
        self.stem = ConvBlock(inputs, c)
        self.down1 = ConvBlock(c, c * 2, stride=2)
        self.down2 = ConvBlock(c * 2, c * 4, stride=2)
        self.body = nn.Sequential(
            *[MobileResidualBlock(c * 4) for _ in range(config.residual_blocks)]
        )
        self.low_frequency = nn.Sequential(
            ConvBlock(c * 4, c * 2),
            nn.Conv2d(c * 2, c * 2, 3, 1, 1),
        )
        self.high_frequency = nn.Sequential(
            MobileResidualBlock(c * 4),
            nn.Conv2d(c * 4, c * 2, 3, 1, 1),
        )
        self.up1 = ConvBlock(c * 6, c * 2)
        self.up2 = ConvBlock(c * 3, c)
        self.residual_head = nn.Conv2d(c, 3, 3, 1, 1)
        self.confidence_head = nn.Conv2d(c, 1, 3, 1, 1)
        self.mask_head = nn.Conv2d(c, 1, 3, 1, 1)
        self.detail_head = nn.Conv2d(c, 3, 3, 1, 1)

    def forward(
        self,
        image: torch.Tensor,
        semantic_masks: torch.Tensor,
        controls: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        height, width = image.shape[-2:]
        control_maps = controls[:, :, None, None].expand(-1, -1, height, width)
        x0 = self.stem(torch.cat((image, semantic_masks, control_maps), dim=1))
        x1 = self.down1(x0)
        x2 = self.body(self.down2(x1))

        pooled = F.avg_pool2d(x2, kernel_size=5, stride=1, padding=2)
        low = self.low_frequency(pooled)
        high = self.high_frequency(x2 - pooled)
        fused = torch.cat((low, high), dim=1)

        up1 = F.interpolate(fused, size=x1.shape[-2:], mode="bilinear", align_corners=False)
        up1 = self.up1(torch.cat((up1, x1), dim=1))
        up2 = F.interpolate(up1, size=x0.shape[-2:], mode="bilinear", align_corners=False)
        features = self.up2(torch.cat((up2, x0), dim=1))

        residual = torch.tanh(self.residual_head(features)) * 0.25
        confidence = torch.sigmoid(self.confidence_head(features))
        refined_skin_mask = torch.sigmoid(self.mask_head(features))
        detail = torch.tanh(self.detail_head(features)) * 0.08
        return residual, confidence, refined_skin_mask, detail

    @staticmethod
    def composite(
        image: torch.Tensor,
        residual: torch.Tensor,
        confidence: torch.Tensor,
        refined_skin_mask: torch.Tensor,
        detail: torch.Tensor,
        master_strength: torch.Tensor,
    ) -> torch.Tensor:
        strength = master_strength[:, None, None, None].clamp(0, 1)
        alpha = confidence * refined_skin_mask * strength
        return (image + alpha * residual + alpha * detail).clamp(0, 1)

