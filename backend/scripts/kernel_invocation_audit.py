#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT = "/tmp/bb-kernel-invocation-audit.json"
DEFAULT_COMPILED_DIR = "backend/infra/vm/build/kernel"
CORPUS_ENTRYPOINT = ".beepbeep.tests.corpus.printJson"
ARTIFACT_BY_KIND = {
    "request-talk-turn": "request-talk-turn.uc",
    "release-talk-turn": "release-talk-turn.uc",
    "RequestTalkTurn": "request-talk-turn.uc",
    "ReleaseTalkTurn": "release-talk-turn.uc",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Measure compiled Unison kernel invocation latency.")
    parser.add_argument("--project", default="bb/main")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--compiled-dir", default=DEFAULT_COMPILED_DIR)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    compiled_dir = (repo_root / args.compiled_dir).resolve()
    if args.dry_run:
        cases = [
            {
                "id": "dry-run",
                "kind": "request-talk-turn",
                "artifact": str(compiled_dir / "request-talk-turn.uc"),
                "command": corpus_command(args.project),
            }
        ]
        return write_summary(args, repo_root, compiled_dir, cases, [], ok=True)

    corpus_result = run_command(corpus_command(args.project), cwd=repo_root)
    if not corpus_result["ok"]:
        return write_summary(
            args,
            repo_root,
            compiled_dir,
            [],
            [corpus_result | {"name": "kernel-corpus"}],
            ok=False,
        )
    try:
        cases = extract_cases(json.loads(corpus_result["stdout"]))
    except Exception as error:
        return write_summary(
            args,
            repo_root,
            compiled_dir,
            [],
            [{"name": "parse-corpus", "ok": False, "error": str(error)}],
            ok=False,
        )

    selected = cases[: max(args.limit, 0)]
    measurements = [
        measure_case(case, repo_root=repo_root, compiled_dir=compiled_dir)
        for case in selected
    ]
    ok = all(item.get("ok") for item in measurements)
    return write_summary(args, repo_root, compiled_dir, selected, measurements, ok=ok)


def corpus_command(project: str) -> list[str]:
    return ["direnv", "exec", ".", "ucm", "run", f"{project}:{CORPUS_ENTRYPOINT}"]


def compiled_command(*, artifact: Path, input_text: str) -> list[str]:
    return ["direnv", "exec", ".", "ucm", "run.compiled", str(artifact), input_text]


def extract_cases(corpus_json: Any) -> list[dict[str, Any]]:
    if isinstance(corpus_json, dict):
        if isinstance(corpus_json.get("corpus"), dict) and isinstance(corpus_json["corpus"].get("cases"), list):
            return corpus_json["corpus"]["cases"]
        if isinstance(corpus_json.get("cases"), list):
            return corpus_json["cases"]
    raise ValueError("kernel corpus JSON did not contain cases")


def measure_case(case: dict[str, Any], *, repo_root: Path, compiled_dir: Path) -> dict[str, Any]:
    kind = str(case.get("kind", ""))
    artifact_name = ARTIFACT_BY_KIND.get(kind)
    if artifact_name is None:
        return {"id": case.get("id"), "kind": kind, "ok": False, "reason": "unsupported corpus case kind"}
    input_value = {
        "command": case.get("command"),
        "snapshot": case.get("snapshot"),
        "policy": case.get("policy"),
    }
    input_text = json.dumps(input_value, separators=(",", ":"), sort_keys=True)
    artifact = compiled_dir / artifact_name
    command = compiled_command(artifact=artifact, input_text=input_text)
    result = run_command(command, cwd=repo_root)
    decision_kind = None
    if result["ok"]:
        try:
            decision = json.loads(result["stdout"])
            decision_kind = decision.get("kind")
        except Exception:
            result["ok"] = False
            result["reason"] = "compiled worker response was not JSON"
    return {
        "id": case.get("id"),
        "kind": kind,
        "artifact": str(artifact),
        "ok": result["ok"],
        "elapsedMs": result["elapsedMs"],
        "decisionKind": decision_kind,
        "requestHash": sha256_hex(input_text.encode()),
        "responseHash": sha256_hex(result["stdout"].encode()) if result.get("stdout") else None,
        "exitCode": result["exitCode"],
        "stderr": result["stderr"][-1000:],
        **({"reason": result["reason"]} if result.get("reason") else {}),
    }


def run_command(command: list[str], *, cwd: Path) -> dict[str, Any]:
    started = time.monotonic()
    completed = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    elapsed_ms = round((time.monotonic() - started) * 1000)
    return {
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "elapsedMs": elapsed_ms,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def write_summary(
    args: argparse.Namespace,
    repo_root: Path,
    compiled_dir: Path,
    cases: list[dict[str, Any]],
    measurements: list[dict[str, Any]],
    *,
    ok: bool,
) -> int:
    elapsed_values = [item["elapsedMs"] for item in measurements if item.get("ok") and "elapsedMs" in item]
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "dryRun": args.dry_run,
        "repoRoot": str(repo_root),
        "compiledDir": str(compiled_dir),
        "limit": args.limit,
        "caseCount": len(cases),
        "measurementCount": len(measurements),
        "elapsedMs": summarize_elapsed(elapsed_values),
        "measurements": measurements,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"kernel invocation audit status: {summary['status']}")
    print(f"kernel invocation audit artifact: {output}")
    return 0 if ok else 1


def summarize_elapsed(values: list[int]) -> dict[str, Any]:
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "mean": round(sum(ordered) / len(ordered), 1),
        "p50": percentile(ordered, 0.50),
        "p95": percentile(ordered, 0.95),
    }


def percentile(ordered: list[int], p: float) -> int:
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * p)))
    return ordered[index]


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
