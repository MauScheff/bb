#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT_DIR = Path("/tmp/turbo-slo-dashboard")
SYNTHETIC_SUCCESS_TARGET = 0.99
BACKEND_SUCCESS_TARGET = 0.99
FULL_PROBE_P95_TARGET_MS = 120_000
CRITICAL_CHECK_P95_TARGET_MS = 2_500
CRITICAL_CHECKS = (
    "channel-readiness:caller:receiver-ready",
    "channel-readiness:callee:receiver-ready",
    "channel-begin-transmit",
    "wake-events:recent:after-begin-transmit",
    "channel-end-transmit",
)


@dataclass(frozen=True)
class Objective:
    name: str
    status: str
    observed: str
    target: str
    source: str
    details: dict[str, Any]

    def to_json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "status": self.status,
            "observed": self.observed,
            "target": self.target,
            "source": self.source,
            "details": self.details,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a static Turbo SLO dashboard from probe and diagnostics artifacts."
    )
    parser.add_argument("--synthetic-conversation", action="append", default=[])
    parser.add_argument("--backend-stability", action="append", default=[])
    parser.add_argument("--merged-diagnostics-json", action="append", default=[])
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--name", default="turbo-slo-dashboard")
    parser.add_argument("--fail-on-breach", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sources = collect_sources(args)
    if not any(sources.values()):
        raise SystemExit("at least one SLO source artifact is required")

    objectives: list[Objective] = []
    objectives.extend(synthetic_objectives(sources["syntheticConversation"]))
    objectives.extend(backend_stability_objectives(sources["backendStability"]))
    objectives.extend(diagnostics_objectives(sources["mergedDiagnostics"]))

    breached = [objective for objective in objectives if objective.status == "breach"]
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_at = utc_now()
    dashboard = {
        "schemaVersion": 1,
        "name": args.name,
        "generatedAt": generated_at,
        "ok": not breached,
        "status": "pass" if not breached else "breach",
        "sources": source_index(sources),
        "summary": {
            "objectiveCount": len(objectives),
            "passed": sum(1 for objective in objectives if objective.status == "pass"),
            "breached": len(breached),
            "noData": sum(1 for objective in objectives if objective.status == "no-data"),
        },
        "objectives": [objective.to_json() for objective in objectives],
    }

    write_json(output_dir / "slo-dashboard.json", dashboard)
    (output_dir / "slo-dashboard.md").write_text(render_markdown(dashboard), encoding="utf-8")
    write_reproduce_script(output_dir, args)

    print(f"SLO dashboard status: {dashboard['status']}")
    print(f"SLO dashboard artifacts: {output_dir}")
    return 2 if breached and args.fail_on_breach else 0


def collect_sources(args: argparse.Namespace) -> dict[str, list[dict[str, Any]]]:
    return {
        "syntheticConversation": read_artifacts(args.synthetic_conversation),
        "backendStability": read_artifacts(args.backend_stability),
        "mergedDiagnostics": read_artifacts(args.merged_diagnostics_json),
    }


def read_artifacts(paths: list[str]) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for raw_path in paths:
        path = Path(raw_path)
        payload = read_json(path)
        payload["_sourcePath"] = str(path)
        artifacts.append(payload)
    return artifacts


def synthetic_objectives(artifacts: list[dict[str, Any]]) -> list[Objective]:
    if not artifacts:
        return []

    total = sum(int_value(artifact.get("iterationsRun")) for artifact in artifacts)
    passed = sum(int_value(artifact.get("passed")) for artifact in artifacts)
    failed = sum(int_value(artifact.get("failed")) for artifact in artifacts)
    success_rate = passed / total if total else None
    source = joined_sources(artifacts)
    objectives = [
        threshold_objective(
            name="synthetic_conversation_success_rate",
            value=success_rate,
            comparator=">=",
            target=SYNTHETIC_SUCCESS_TARGET,
            observed=format_percent(success_rate),
            target_text=f">= {format_percent(SYNTHETIC_SUCCESS_TARGET)}",
            source=source,
            details={"iterations": total, "passed": passed, "failed": failed},
            missing_is_breach=True,
        )
    ]

    durations = [
        int_value(iteration.get("durationMs"))
        for artifact in artifacts
        for iteration in artifact.get("iterations", [])
        if isinstance(iteration, dict) and iteration.get("durationMs") is not None
    ]
    full_probe_p95 = percentile(durations, 95) if durations else None
    objectives.append(
        threshold_objective(
            name="synthetic_conversation_full_probe_p95_ms",
            value=full_probe_p95,
            comparator="<=",
            target=FULL_PROBE_P95_TARGET_MS,
            observed=format_ms(full_probe_p95),
            target_text=f"<= {FULL_PROBE_P95_TARGET_MS}ms",
            source=source,
            details={"sampleCount": len(durations)},
            missing_is_breach=True,
        )
    )

    stats_by_name = aggregate_check_stats(artifacts)
    missing_checks = [name for name in CRITICAL_CHECKS if name not in stats_by_name]
    failing_checks = [
        name
        for name, stat_payload in stats_by_name.items()
        if name in CRITICAL_CHECKS and int_value(stat_payload.get("failed")) > 0
    ]
    objectives.append(
        Objective(
            name="synthetic_conversation_critical_checks_present",
            status="pass" if not missing_checks and not failing_checks else "breach",
            observed="all present and passing" if not missing_checks and not failing_checks else "missing or failing",
            target="required checks present, zero failures",
            source=source,
            details={"missing": missing_checks, "failing": failing_checks},
        )
    )

    for check_name in CRITICAL_CHECKS:
        stat_payload = stats_by_name.get(check_name)
        p95 = int_value(stat_payload.get("p95DurationMs")) if stat_payload else None
        objectives.append(
            threshold_objective(
                name=f"synthetic_{sanitize_name(check_name)}_p95_ms",
                value=p95,
                comparator="<=",
                target=CRITICAL_CHECK_P95_TARGET_MS,
                observed=format_ms(p95),
                target_text=f"<= {CRITICAL_CHECK_P95_TARGET_MS}ms",
                source=source,
                details={"check": check_name, "sampleCount": int_value(stat_payload.get("count")) if stat_payload else 0},
                missing_is_breach=True,
            )
        )

    return objectives


def backend_stability_objectives(artifacts: list[dict[str, Any]]) -> list[Objective]:
    objectives: list[Objective] = []
    for artifact in artifacts:
        source = str(artifact.get("_sourcePath") or "backend-stability")
        summary = artifact.get("summary")
        if not isinstance(summary, dict):
            objectives.append(
                Objective(
                    name="backend_stability_summary_present",
                    status="breach",
                    observed="missing summary",
                    target="backend stability summary present",
                    source=source,
                    details={},
                )
            )
            continue
        for endpoint, endpoint_summary in sorted(summary.items()):
            if not isinstance(endpoint_summary, dict):
                continue
            total = int_value(endpoint_summary.get("total"))
            ok_count = int_value(endpoint_summary.get("ok"))
            success_rate = ok_count / total if total else None
            objectives.append(
                threshold_objective(
                    name=f"backend_{sanitize_name(str(endpoint))}_success_rate",
                    value=success_rate,
                    comparator=">=",
                    target=BACKEND_SUCCESS_TARGET,
                    observed=format_percent(success_rate),
                    target_text=f">= {format_percent(BACKEND_SUCCESS_TARGET)}",
                    source=source,
                    details={
                        "endpoint": endpoint,
                        "total": total,
                        "ok": ok_count,
                        "failed": int_value(endpoint_summary.get("failed")),
                        "maxMs": endpoint_summary.get("maxMs"),
                    },
                )
            )
    return objectives


def diagnostics_objectives(artifacts: list[dict[str, Any]]) -> list[Objective]:
    if not artifacts:
        return []

    current_violations: list[dict[str, Any]] = []
    historical_violations: list[dict[str, Any]] = []
    for artifact in artifacts:
        artifact_current, artifact_historical = split_diagnostics_violations(artifact)
        current_violations.extend(artifact_current)
        historical_violations.extend(artifact_historical)

    by_id: dict[str, int] = {}
    for violation in current_violations:
        invariant_id = str(violation.get("invariantId") or "unknown")
        by_id[invariant_id] = by_id.get(invariant_id, 0) + 1

    historical_by_id: dict[str, int] = {}
    for violation in historical_violations:
        invariant_id = str(violation.get("invariantId") or "unknown")
        historical_by_id[invariant_id] = historical_by_id.get(invariant_id, 0) + 1

    return [
        Objective(
            name="merged_diagnostics_invariant_violations",
            status="pass" if not current_violations else "breach",
            observed=str(len(current_violations)),
            target="0",
            source=joined_sources(artifacts),
            details={
                "currentCount": len(current_violations),
                "historicalCount": len(historical_violations),
                "byInvariantId": dict(sorted(by_id.items())),
                "historicalByInvariantId": dict(sorted(historical_by_id.items())),
            },
        )
    ]


def split_diagnostics_violations(
    artifact: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    has_split_keys = "currentViolations" in artifact or "historicalViolations" in artifact
    if has_split_keys:
        current = artifact.get("currentViolations")
        historical = artifact.get("historicalViolations")
        return (
            [item for item in current if isinstance(item, dict)] if isinstance(current, list) else [],
            [item for item in historical if isinstance(item, dict)] if isinstance(historical, list) else [],
        )

    artifact_violations = artifact.get("violations")
    if isinstance(artifact_violations, list):
        return ([item for item in artifact_violations if isinstance(item, dict)], [])
    return ([], [])


def aggregate_check_stats(artifacts: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for artifact in artifacts:
        stats = artifact.get("checkStats")
        if not isinstance(stats, list):
            continue
        for stat_payload in stats:
            if not isinstance(stat_payload, dict):
                continue
            name = str(stat_payload.get("name") or "")
            if name:
                grouped.setdefault(name, []).append(stat_payload)

    aggregate: dict[str, dict[str, Any]] = {}
    for name, stats in grouped.items():
        p95s = [int_value(stat_payload.get("p95DurationMs")) for stat_payload in stats if stat_payload.get("p95DurationMs") is not None]
        aggregate[name] = {
            "name": name,
            "count": sum(int_value(stat_payload.get("count")) for stat_payload in stats),
            "passed": sum(int_value(stat_payload.get("passed")) for stat_payload in stats),
            "failed": sum(int_value(stat_payload.get("failed")) for stat_payload in stats),
            "p95DurationMs": max(p95s) if p95s else None,
        }
    return aggregate


def threshold_objective(
    *,
    name: str,
    value: float | int | None,
    comparator: str,
    target: float | int,
    observed: str,
    target_text: str,
    source: str,
    details: dict[str, Any],
    missing_is_breach: bool = False,
) -> Objective:
    if value is None:
        status = "breach" if missing_is_breach else "no-data"
    elif comparator == ">=":
        status = "pass" if value >= target else "breach"
    elif comparator == "<=":
        status = "pass" if value <= target else "breach"
    else:
        raise ValueError(f"unsupported comparator {comparator}")

    return Objective(
        name=name,
        status=status,
        observed=observed,
        target=target_text,
        source=source,
        details=details,
    )


def percentile(values: list[int], percent: int) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    index = round((percent / 100) * (len(ordered) - 1))
    return ordered[index]


def int_value(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


def format_percent(value: float | None) -> str:
    if value is None:
        return "no data"
    return f"{value * 100:.2f}%"


def format_ms(value: int | float | None) -> str:
    if value is None:
        return "no data"
    return f"{int(value)}ms"


def sanitize_name(value: str) -> str:
    return "".join(char if char.isalnum() else "_" for char in value).strip("_")


def joined_sources(artifacts: list[dict[str, Any]]) -> str:
    return ", ".join(str(artifact.get("_sourcePath") or "unknown") for artifact in artifacts)


def source_index(sources: dict[str, list[dict[str, Any]]]) -> dict[str, list[str]]:
    return {
        name: [str(artifact.get("_sourcePath") or "unknown") for artifact in artifacts]
        for name, artifacts in sources.items()
        if artifacts
    }


def render_markdown(dashboard: dict[str, Any]) -> str:
    lines = [
        f"# {dashboard['name']}",
        "",
        f"Generated: {dashboard['generatedAt']}",
        f"Status: {str(dashboard['status']).upper()}",
        "",
        "## Sources",
    ]
    sources = dashboard.get("sources", {})
    if isinstance(sources, dict) and sources:
        for source_type, paths in sorted(sources.items()):
            if isinstance(paths, list):
                lines.append(f"- {source_type}: {', '.join(str(path) for path in paths)}")
    else:
        lines.append("- none")

    lines.extend([
        "",
        "## Objectives",
        "",
        "| Status | Objective | Observed | Target | Source |",
        "| --- | --- | --- | --- | --- |",
    ])
    objectives = dashboard.get("objectives", [])
    if isinstance(objectives, list):
        for objective in objectives:
            if not isinstance(objective, dict):
                continue
            lines.append(
                "| "
                + " | ".join(
                    escape_markdown_table(str(value))
                    for value in [
                        objective.get("status", ""),
                        objective.get("name", ""),
                        objective.get("observed", ""),
                        objective.get("target", ""),
                        objective.get("source", ""),
                    ]
                )
                + " |"
            )
    return "\n".join(lines) + "\n"


def escape_markdown_table(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def write_reproduce_script(output_dir: Path, args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        "tools/scripts/slo_dashboard.py",
        "--output-dir",
        str(output_dir),
        "--name",
        args.name,
    ]
    for path in args.synthetic_conversation:
        command.extend(["--synthetic-conversation", path])
    for path in args.backend_stability:
        command.extend(["--backend-stability", path])
    for path in args.merged_diagnostics_json:
        command.extend(["--merged-diagnostics-json", path])
    if args.fail_on_breach:
        command.append("--fail-on-breach")

    script = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"cd {shell_quote(str(Path.cwd()))}\n"
        + " ".join(shell_quote(part) for part in command)
        + "\n"
    )
    path = output_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit(f"expected JSON object in {path}")
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
