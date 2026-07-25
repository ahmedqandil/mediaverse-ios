from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from .manifest import audit_identity_splits
from .provenance import digest


REQUIRED_METRICS = {
    "zero_strength_max_delta": ("max", 1e-6),
    "background_mean_delta": ("max", 0.01),
    "protected_feature_mean_delta": ("max", 0.02),
    "coreml_max_delta": ("max", 0.003),
    "preview_export_mean_delta": ("max", 0.01),
}


def check_metrics(metrics: dict[str, float]) -> list[str]:
    failures: list[str] = []
    for name, (comparison, threshold) in REQUIRED_METRICS.items():
        if name not in metrics:
            failures.append(f"missing metric: {name}")
            continue
        value = float(metrics[name])
        if comparison == "max" and value > threshold:
            failures.append(f"{name}={value} exceeds {threshold}")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--coreml-model", type=Path, required=True)
    parser.add_argument("--manifests", type=Path, nargs="+", required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--model-card", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    for path in (
        args.checkpoint,
        args.coreml_model,
        *args.manifests,
        args.metrics,
        args.model_card,
    ):
        if not path.exists():
            raise SystemExit(f"release gate failed: missing {path}")

    metrics = json.loads(args.metrics.read_text(encoding="utf-8"))
    failures = check_metrics(metrics)
    dataset_audit = audit_identity_splits(args.manifests, check_files=True)
    if dataset_audit["splits"].get("validation", 0) == 0:
        failures.append("validation split is empty")
    if dataset_audit["splits"].get("test", 0) == 0:
        failures.append("test split is empty")

    parity = subprocess.run(
        [
            sys.executable,
            "-m",
            "beauty_engine.parity",
            "--checkpoint",
            str(args.checkpoint),
            "--model",
            str(args.coreml_model),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if parity.returncode != 0:
        failures.append(f"Core ML parity failed: {parity.stderr.strip() or parity.stdout.strip()}")

    report = {
        "passed": not failures,
        "failures": failures,
        "dataset_audit": dataset_audit,
        "metrics": metrics,
        "artifacts": {
            "checkpoint": str(args.checkpoint),
            "checkpoint_sha256": digest(args.checkpoint),
            "coreml_model": str(args.coreml_model),
            "model_card": str(args.model_card),
            "model_card_sha256": digest(args.model_card),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        raise SystemExit("release gate failed")


if __name__ == "__main__":
    main()
