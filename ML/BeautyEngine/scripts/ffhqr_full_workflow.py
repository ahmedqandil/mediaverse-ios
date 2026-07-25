"""Durable official FFHQ + FFHQR research download, preparation, and training."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

FFHQR_URLS = tuple(
    f"https://www.cs.ubc.ca/research/AutoRetouch/ffhqr.part{part}.tar"
    for part in range(1, 8)
)
OFFICIAL_SOURCES = {
    "ffhq_repository": "https://github.com/NVlabs/ffhq-dataset",
    "ffhq_downloader": (
        "https://raw.githubusercontent.com/NVlabs/ffhq-dataset/"
        "master/download_ffhq.py"
    ),
    "ffhqr_repository": "https://github.com/skylab-tech/ffhqr-dataset",
    "ffhqr_archives": FFHQR_URLS,
}
MINIMUM_FREE_BYTES = 300 * 1024**3


def stamp() -> str:
    return datetime.now(UTC).isoformat()


def run(command: list[str], *, cwd: Path | None = None) -> None:
    print(json.dumps({"at": stamp(), "command": command, "cwd": str(cwd or Path.cwd())}))
    subprocess.run(command, cwd=cwd, check=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_disk_space(path: Path) -> None:
    free = shutil.disk_usage(path).free
    print(json.dumps({"at": stamp(), "free_bytes": free, "path": str(path)}))
    if free < MINIMUM_FREE_BYTES:
        raise RuntimeError(
            f"refusing workflow with {free / 1024**3:.1f} GiB free; 300 GiB required"
        )


def safe_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError(f"unsafe archive path: {member.name}")
        if not (member.isfile() or member.isdir()):
            raise RuntimeError(f"unsupported archive member type: {member.name}")
    return members


def extract_validated(archive_path: Path, destination: Path) -> None:
    marker = destination / f".{archive_path.name}.extracted"
    if marker.exists():
        return
    with tarfile.open(archive_path, "r:") as archive:
        members = safe_members(archive)
        print(
            json.dumps(
                {
                    "at": stamp(),
                    "archive": str(archive_path),
                    "validated_members": len(members),
                }
            )
        )
        archive.extractall(destination, members=members)
    marker.write_text(stamp() + "\n", encoding="utf-8")


def count_pngs(path: Path) -> int:
    return sum(1 for item in path.rglob("*.png") if item.is_file())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--ffhq-threads", type=int, default=4)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    engine_root = project_root / "ML" / "BeautyEngine"
    dataset_root = args.dataset_root.resolve()
    sources = dataset_root / "sources"
    downloads = dataset_root / "downloads"
    ffhq_root = dataset_root / "ffhq"
    ffhqr_root = dataset_root / "ffhqr"
    prepared_root = engine_root / "research" / "ffhqr"
    state = dataset_root / "state"
    for path in (sources, downloads, ffhq_root, ffhqr_root, prepared_root, state):
        path.mkdir(parents=True, exist_ok=True)

    require_disk_space(dataset_root)
    provenance_path = state / "source-provenance.json"
    provenance = {
        "created_at": stamp(),
        "usage_scope": "research_noncommercial",
        "license": "CC-BY-NC-SA-4.0",
        "citation": "Shafaei, Little, and Schmidt, AutoRetouch, WACV 2021",
        "official_sources": OFFICIAL_SOURCES,
    }
    provenance_path.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    ffhq_downloader = sources / "ffhq-download_ffhq.py"
    if not ffhq_downloader.is_file():
        run(
            [
                "curl",
                "-fL",
                "--retry",
                "5",
                "-o",
                str(ffhq_downloader),
                OFFICIAL_SOURCES["ffhq_downloader"],
            ]
        )
    if count_pngs(ffhq_root / "images1024x1024") != 70_000:
        run(
            [
                sys.executable,
                str(ffhq_downloader),
                "--images",
                "--num_threads",
                str(args.ffhq_threads),
                "--status_delay",
                "5",
            ],
            cwd=ffhq_root,
        )

    archive_provenance = []
    for url in FFHQR_URLS:
        archive_path = downloads / Path(url).name
        run(
            [
                "curl",
                "-fL",
                "-C",
                "-",
                "--retry",
                "20",
                "--retry-all-errors",
                "--retry-delay",
                "10",
                "--speed-time",
                "120",
                "--speed-limit",
                "1024",
                "-o",
                str(archive_path),
                url,
            ]
        )
        archive_provenance.append(
            {
                "url": url,
                "path": str(archive_path),
                "bytes": archive_path.stat().st_size,
                "sha256": sha256(archive_path),
            }
        )
        extract_validated(archive_path, ffhqr_root)
        require_disk_space(dataset_root)

    provenance["archives"] = archive_provenance
    provenance["updated_at"] = stamp()
    provenance_path.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    ffhq_images = ffhq_root / "images1024x1024"
    if count_pngs(ffhq_images) != 70_000:
        raise RuntimeError("FFHQ validation failed: expected 70,000 PNG files")
    if count_pngs(ffhqr_root) != 70_000:
        raise RuntimeError("FFHQR validation failed: expected 70,000 PNG files")

    run(
        [
            sys.executable,
            "-m",
            "beauty_engine.ffhqr",
            "--ffhq-root",
            str(ffhq_images),
            "--ffhqr-root",
            str(ffhqr_root),
            "--output",
            str(prepared_root / "index.jsonl"),
            "--prepare-training",
            "--face-parser",
            str(
                project_root
                / "Mediaverse-Swift"
                / "Resources"
                / "ML"
                / "FaceParser.mlpackage"
            ),
        ],
        cwd=engine_root,
    )
    run(
        [
            sys.executable,
            "-m",
            "beauty_engine.manifest",
            str(prepared_root / "manifests" / "train.jsonl"),
            "--additional",
            str(prepared_root / "manifests" / "validation.jsonl"),
            str(prepared_root / "manifests" / "test.jsonl"),
            "--mode",
            "research_noncommercial",
        ],
        cwd=engine_root,
    )

    checkpoint = engine_root / "research" / "checkpoints" / "ffhqr-render" / "latest.pt"
    training_command = [
        sys.executable,
        "-m",
        "beauty_engine.train",
        "--config",
        "configs/ffhqr-render-research.yaml",
    ]
    if checkpoint.is_file():
        training_command.extend(["--resume", str(checkpoint)])
    os.environ["PYTHONPATH"] = str(engine_root)
    run(training_command, cwd=engine_root)


if __name__ == "__main__":
    main()
