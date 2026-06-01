#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT_DIR = "backend/infra/vm/build/kernel"
KERNEL_ARTIFACTS = [
    (
        "request-talk-turn",
        ".beepbeep.worker.requestTalkTurn.printDecisionJson",
    ),
    (
        "release-talk-turn",
        ".beepbeep.worker.releaseTalkTurn.printDecisionJson",
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile Unison kernel worker entrypoints into deployable .uc artifacts."
    )
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--project", default="bb/main")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--summary", default="/tmp/turbo-kernel-compile.json")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    output_dir = (repo_root / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    steps = [
        compile_artifact(
            repo_root=repo_root,
            output_dir=output_dir,
            project=args.project,
            name=name,
            entrypoint=entrypoint,
            dry_run=args.dry_run,
        )
        for name, entrypoint in KERNEL_ARTIFACTS
    ]
    ok = all(step["ok"] for step in steps)
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "dryRun": args.dry_run,
        "outputDir": str(output_dir),
        "artifacts": [
            str(output_dir / f"{name}.uc")
            for name, _ in KERNEL_ARTIFACTS
        ],
        "steps": steps,
    }
    summary_path = Path(args.summary)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"kernel compile status: {summary['status']}")
    print(f"kernel compile artifact: {summary_path}")
    return 0 if ok else 1


def compile_artifact(
    *,
    repo_root: Path,
    output_dir: Path,
    project: str,
    name: str,
    entrypoint: str,
    dry_run: bool,
) -> dict[str, Any]:
    temp_name = f"turbo-kernel-{name}"
    temp_artifact = repo_root / f"{temp_name}.uc"
    output_artifact = output_dir / f"{name}.uc"
    command_text = f"compile {entrypoint} {temp_name}\nquit\n"
    command = ["direnv", "exec", ".", "ucm", "-p", project, "--no-file-watch"]
    if dry_run:
        return {
            "name": name,
            "ok": True,
            "dryRun": True,
            "entrypoint": entrypoint,
            "output": str(output_artifact),
            "command": command,
            "stdin": command_text,
        }
    if temp_artifact.exists():
        temp_artifact.unlink()
    completed = subprocess.run(
        command,
        input=command_text,
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0 or not temp_artifact.exists():
        return {
            "name": name,
            "ok": False,
            "entrypoint": entrypoint,
            "output": str(output_artifact),
            "exitCode": completed.returncode,
            "stdout": completed.stdout.strip()[-4000:],
            "stderr": completed.stderr.strip()[-4000:],
            "reason": "compiled artifact was not created",
        }
    shutil.move(str(temp_artifact), output_artifact)
    return {
        "name": name,
        "ok": True,
        "entrypoint": entrypoint,
        "output": str(output_artifact),
        "bytes": output_artifact.stat().st_size,
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
