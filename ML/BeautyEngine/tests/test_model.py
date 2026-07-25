from __future__ import annotations

import unittest

import torch

from beauty_engine.losses import BeautyLoss, monotonicity_loss, temporal_warp_loss, zero_state_loss
from beauty_engine.model import BeautyEngine, BeautyEngineConfig
from beauty_engine.release_gate import check_metrics


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

    def test_any_individual_control_can_enable_effect(self) -> None:
        controls = torch.zeros(2, 8)
        controls[0, 0] = 0.5
        controls[1, 7] = 0.5
        strengths = 1 - torch.prod(1 - controls, dim=1)
        self.assertTrue(torch.equal(strengths, torch.tensor([0.5, 0.5])))

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

    def test_zero_state_loss_detects_any_change(self) -> None:
        source = torch.zeros(1, 3, 8, 8)
        self.assertEqual(float(zero_state_loss(source, source.clone())), 0)
        changed = source.clone()
        changed[:, :, 0, 0] = 0.01
        self.assertGreater(float(zero_state_loss(source, changed)), 0)

    def test_monotonicity_rejects_weaker_control_with_larger_delta(self) -> None:
        source = torch.zeros(1, 3, 8, 8)
        weaker = torch.full_like(source, 0.2)
        stronger = torch.full_like(source, 0.1)
        self.assertGreater(float(monotonicity_loss(source, weaker, stronger)), 0)

    def test_temporal_loss_ignores_occluded_pixels(self) -> None:
        current = torch.ones(1, 3, 8, 8)
        previous = torch.zeros_like(current)
        invisible = torch.zeros(1, 1, 8, 8)
        visible = torch.ones_like(invisible)
        self.assertLess(
            float(temporal_warp_loss(current, previous, invisible)),
            float(temporal_warp_loss(current, previous, visible)),
        )

    def test_release_metrics_reject_missing_and_excessive_values(self) -> None:
        failures = check_metrics(
            {
                "zero_strength_max_delta": 0,
                "background_mean_delta": 0.02,
            }
        )
        self.assertTrue(any("background_mean_delta" in failure for failure in failures))
        self.assertTrue(any("missing metric" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
