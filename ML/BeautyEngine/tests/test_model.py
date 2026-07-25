from __future__ import annotations

import unittest

import torch

from beauty_engine.losses import BeautyLoss
from beauty_engine.model import BeautyEngine, BeautyEngineConfig


class ModelTests(unittest.TestCase):
    def setUp(self) -> None:
        torch.manual_seed(7)
        self.model = BeautyEngine(
            BeautyEngineConfig(
                semantic_channels=8,
                control_count=8,
                base_channels=8,
                residual_blocks=2,
            )
        )

    def test_shapes_and_bounds(self) -> None:
        image = torch.rand(2, 3, 64, 64)
        masks = torch.rand(2, 8, 64, 64)
        controls = torch.rand(2, 8)
        residual, confidence, refined_skin, detail = self.model(image, masks, controls)
        self.assertEqual(residual.shape, image.shape)
        self.assertEqual(detail.shape, image.shape)
        self.assertEqual(confidence.shape, (2, 1, 64, 64))
        self.assertTrue(torch.all((confidence >= 0) & (confidence <= 1)))
        self.assertTrue(torch.all((refined_skin >= 0) & (refined_skin <= 1)))

    def test_zero_master_is_pixel_identical(self) -> None:
        image = torch.rand(1, 3, 32, 32)
        masks = torch.rand(1, 8, 32, 32)
        controls = torch.rand(1, 8)
        outputs = self.model(image, masks, controls)
        result = self.model.composite(image, *outputs, torch.zeros(1))
        self.assertTrue(torch.equal(image, result))

    def test_loss_penalizes_background_changes(self) -> None:
        source = torch.zeros(1, 3, 16, 16)
        target = source.clone()
        output = source.clone()
        output[:, :, :4, :4] = 1
        skin = torch.zeros(1, 1, 16, 16)
        loss, terms = BeautyLoss({"background": 1.0})(
            source,
            target,
            output,
            torch.ones_like(skin),
            torch.full_like(skin, 0.5),
            skin,
        )
        self.assertGreater(float(loss), 0)
        self.assertGreater(float(terms["background"]), 0)


if __name__ == "__main__":
    unittest.main()

