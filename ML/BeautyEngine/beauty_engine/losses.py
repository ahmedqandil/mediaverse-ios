from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F


def charbonnier(value: torch.Tensor, epsilon: float = 1e-3) -> torch.Tensor:
    return torch.sqrt(value * value + epsilon * epsilon).mean()


def gradients(value: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    return value[:, :, :, 1:] - value[:, :, :, :-1], value[:, :, 1:, :] - value[:, :, :-1, :]


def laplacian_level(value: torch.Tensor) -> torch.Tensor:
    low = F.avg_pool2d(value, kernel_size=2, stride=2)
    return value - F.interpolate(low, size=value.shape[-2:], mode="bilinear", align_corners=False)


class BeautyLoss(nn.Module):
    def __init__(self, weights: dict[str, float]) -> None:
        super().__init__()
        self.weights = weights

    def forward(
        self,
        source: torch.Tensor,
        target: torch.Tensor,
        output: torch.Tensor,
        confidence: torch.Tensor,
        refined_skin: torch.Tensor,
        semantic_skin: torch.Tensor,
    ) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
        allowed = semantic_skin.clamp(0, 1)
        background = 1 - allowed
        reconstruction = charbonnier((output - target) * allowed)
        background_identity = charbonnier((output - source) * background)
        frequency = charbonnier(laplacian_level(output) - laplacian_level(target))
        out_dx, out_dy = gradients(output)
        target_dx, target_dy = gradients(target)
        texture = charbonnier(out_dx - target_dx) + charbonnier(out_dy - target_dy)
        mask = F.binary_cross_entropy(refined_skin, allowed)
        confidence_regularization = (confidence * background).mean()

        terms = {
            "reconstruction": reconstruction,
            "background": background_identity,
            "frequency": frequency,
            "texture": texture,
            "mask": mask + confidence_regularization,
        }
        total = sum(self.weights.get(name, 0.0) * value for name, value in terms.items())
        return total, terms

