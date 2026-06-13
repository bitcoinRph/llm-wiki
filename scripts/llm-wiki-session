#!/usr/bin/env python3
"""Automated session capture helpers for llm-wiki.

This helper is intentionally deterministic and local-only. Harness hooks call the
`hook` subcommand with one JSON object on stdin. The hook path records a small,
redacted event, updates per-session state under HUB/.sessions, and writes a
markdown digest at configured checkpoints. It never calls an LLM or copies raw
transcripts by default.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEFAULT_TOOL_THRESHOLD = 50
MAX_LAST_EVENTS = 20
MAX_EVENT_PREVIEW_CHARS = 1200
SESSION_ID_SAFE = re.compile(r"[^A-Za-z0-9_.@:+-]+")
SECRET_KEY_RE = re.compile(
    r"(?i)(api[_-]?key|authorization|bearer|token|secret|password|passwd|private[_-]?key|access[_-]?key|session[_-]?cookie|cookie)"
)
SECRET_VALUE_RE = re.compile(
    r"(?i)(bearer\s+)[A-Za-z0-9._~+\-/=]{12,}|"
    r"(sk-[A-Za-z0-9]{12,})|"
    r"([A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,})"
)
CONTENT_KEY_RE = re.compile(
    r"(?i)^(prompt|user_prompt|message|messages|content|transcript|tool_response|tool_output|response|result|stdout|stderr)$"
)

DEFAULT_CONFIG: dict[str, Any] = {
    "schema_version": SCHEMA_VERSION,
    "enabled": False,
    "mode": "capture-only",
    "auto_capture": {
        "tool_events": DEFAULT_TOOL_THRESHOLD,
        "pre_compact": True,
        "post_compact": True,
        "session_end": True,
        "stop": True,
    },
    "rehydrate": {
        "session_start": False,
        "user_prompt": False,
        "strict": False,
    },
    "raw_transcripts": False,
    "privacy": "redacted",
}

BALANCED_CONFIG = {
    "enabled": True,
    "mode": "balanced",
    "auto_capture": {
        "tool_events": DEFAULT_TOOL_THRESHOLD,
        "pre_compact": True,
        "post_compact": True,
        "session_end": True,
        "stop": True,
    },
    "rehydrate": {
        "session_start": True,
        "user_prompt": True,
        "strict": False,
    },
    "raw_transcripts": False,
    "privacy": "redacted",
}

CAPTURE_ONLY_CONFIG = {
    "enabled": True,
    "mode": "capture-only",
    "auto_capture": {
        "tool_events": DEFAULT_TOOL_THRESHOLD,
        "pre_compact": True,
        "post_compact": True,
        "session_end": True,
        "stop": True,
    },
    "rehydrate": {
        "session_start": False,
        "user_prompt": False,
        "strict": False,
    },
    "raw_transcripts": False,
    "privacy": "redacted",
}

AGGRESSIVE_CONFIG = {
    "enabled": True,
    "mode": "aggressive",
    "auto_capture": {
        "tool_events": 25,
        "pre_compact": True,
        "post_compact": True,
        "session_end": True,
        "stop": True,
    },
    "rehydrate": {
        "session_start": True,
        "user_prompt": True,
        "strict": False,
    },
    "raw_transcripts": False,
    "privacy": "redacted",
}

MODE_CONFIGS = {
    "off": {**DEFAULT_CONFIG, "mode": "off"},
    "capture-only": {**DEFAULT_CONFIG, **CAPTURE_ONLY_CONFIG},
    "balanced": {**DEFAULT_CONFIG, **BALANCED_CONFIG},
    "aggressive": {**DEFAULT_CONFIG, **AGGRESSIVE_CONFIG},
}


class HookSkip(Exception):
    """Raised when a hook should silently do nothing."""


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today() -> str:
    return dt.date.today().isoformat()


def expand_leading_tilde(value: str) -> Path:
    if value == "~":
        return Path.home()
    if value.startswith("~/"):
        return Path.home() / value[2:]
    return Path(value)


def resolve_hub(args: argparse.Namespace) -> Path:
    if getattr(args, "local", False):
        return Path.cwd() / ".wiki"
    if getattr(args, "hub", None):
        return expand_leading_tilde(str(args.hub))
    config = Path.home() / ".config" / "llm-wiki" / "config.json"
    if config.exists():
        try:
            data = json.loads(config.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid llm-wiki config {config}: {exc}") from exc
        hub_path = data.get("hub_path") or data.get("resolved_path")
        if hub_path:
            return expand_leading_tilde(str(hub_path))
    return Path.home() / "wiki"


def sessions_dir(hub: Path) -> Path:
    return hub / ".sessions"


def safe_id(value: str) -> str:
    cleaned = SESSION_ID_SAFE.sub("-", value).strip(".-")
    if not cleaned:
        cleaned = hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return cleaned[:120]


def state_path(root: Path, harness: str, native_session_id: str) -> Path:
    return root / "state" / safe_id(harness) / f"{safe_id(native_session_id)}.json"


def digest_path(root: Path, harness: str, native_session_id: str, now: str | None = None) -> Path:
    when = parse_timestamp(now or utc_now())
    return (
        root
        / "digests"
        / f"{when.year:04d}"
        / f"{when.month:02d}"
        / f"{safe_id(harness)}-{safe_id(native_session_id)}.md"
    )


def parse_timestamp(value: str) -> dt.datetime:
    normalized = value.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return dt.datetime.now(dt.UTC)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.UTC)
    return parsed.astimezone(dt.UTC)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: Any) -> None:
    atomic_write(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def append_jsonl(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(data, sort_keys=True, ensure_ascii=False) + "\n")


def merge_dict(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = json.loads(json.dumps(base))
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_dict(result[key], value)
        else:
            result[key] = value
    return result


def load_config(root: Path) -> dict[str, Any]:
    data = merge_dict(DEFAULT_CONFIG, {})
    path = root / "config.json"
    if path.exists():
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            data = merge_dict(data, loaded)
    return data


def mode_config(mode: str) -> dict[str, Any]:
    if mode not in MODE_CONFIGS:
        raise SystemExit(f"unknown session mode: {mode}")
    return merge_dict(DEFAULT_CONFIG, MODE_CONFIGS[mode])


def ensure_layout(root: Path) -> None:
    for rel in ["state", "queue", "digests", "indexes"]:
        (root / rel).mkdir(parents=True, exist_ok=True)


def omitted_value(value: Any) -> str:
    try:
        text = json.dumps(value, sort_keys=True, ensure_ascii=False)
    except TypeError:
        text = str(value)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
    return f"[OMITTED len={len(text)} sha256={digest}]"


def redact_scalar(value: Any, key_hint: str = "") -> Any:
    if value is None or isinstance(value, bool) or isinstance(value, (int, float)):
        return value
    if SECRET_KEY_RE.search(key_hint):
        return "[REDACTED]"
    text = str(value)
    text = SECRET_VALUE_RE.sub(lambda m: (m.group(1) or "") + "[REDACTED]", text)
    if len(text) > MAX_EVENT_PREVIEW_CHARS:
        text = text[:MAX_EVENT_PREVIEW_CHARS] + "…"
    return text


def redact(value: Any, key_hint: str = "") -> Any:
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, nested in value.items():
            key_text = str(key)
            if SECRET_KEY_RE.search(key_text):
                redacted[key_text] = "[REDACTED]"
            elif CONTENT_KEY_RE.search(key_text):
                redacted[key_text] = omitted_value(nested)
            else:
                redacted[key_text] = redact(nested, key_text)
        return redacted
    if isinstance(value, list):
        return [redact(item, key_hint) for item in value[:20]]
    return redact_scalar(value, key_hint)


def compact_json(value: Any, max_chars: int = MAX_EVENT_PREVIEW_CHARS) -> str:
    text = json.dumps(redact(value), sort_keys=True, ensure_ascii=False)
    if len(text) > max_chars:
        return text[:max_chars] + "…"
    return text


def detect_harness(args: argparse.Namespace, payload: dict[str, Any]) -> str:
    if getattr(args, "harness", None):
        return str(args.harness)
    env_harness = os.environ.get("LLM_WIKI_HARNESS")
    if env_harness:
        return env_harness
    if os.environ.get("PLUGIN_ROOT") or "model" in payload:
        return "codex"
    if "permission_mode" in payload or "agent_id" in payload:
        return "claude"
    return "unknown"


def fallback_session_id(payload: dict[str, Any]) -> str:
    parts = [
        str(payload.get("transcript_path") or ""),
        str(payload.get("cwd") or ""),
        str(payload.get("model") or ""),
    ]
    basis = "|".join(parts).strip("|") or utc_now()
    return "derived-" + hashlib.sha256(basis.encode("utf-8")).hexdigest()[:16]


def git_value(cwd: str | None, args: list[str]) -> str | None:
    if not cwd:
        return None
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1.5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value or None


def normalize_event(args: argparse.Namespace, payload: dict[str, Any], root: Path) -> dict[str, Any]:
    now = utc_now()
    harness = safe_id(detect_harness(args, payload))
    native_session_id = str(
        getattr(args, "session_id", None)
        or payload.get("session_id")
        or payload.get("sessionId")
        or fallback_session_id(payload)
    )
    event_name = str(
        getattr(args, "event_name", None)
        or payload.get("hook_event_name")
        or payload.get("hookEventName")
        or payload.get("event")
        or "manual"
    )
    cwd = str(getattr(args, "cwd", None) or payload.get("cwd") or os.getcwd())
    transcript_path = payload.get("transcript_path") or payload.get("transcriptPath")
    tool_name = payload.get("tool_name") or payload.get("toolName") or payload.get("tool")
    trigger = str(getattr(args, "trigger", None) or event_name)
    event = {
        "schema_version": SCHEMA_VERSION,
        "ts": now,
        "event": "session_event",
        "harness": harness,
        "hook_event_name": event_name,
        "native_session_id": native_session_id,
        "llm_wiki_session_id": f"{harness}:{native_session_id}",
        "cwd": cwd,
        "transcript_path": str(transcript_path) if transcript_path else None,
        "model": payload.get("model"),
        "turn_id": payload.get("turn_id") or payload.get("turnId"),
        "tool_name": str(tool_name) if tool_name else None,
        "tool_use_id": payload.get("tool_use_id") or payload.get("toolUseId"),
        "trigger": trigger,
        "payload_preview": compact_json(payload, max_chars=int(getattr(args, "max_event_bytes", MAX_EVENT_PREVIEW_CHARS))),
    }
    if getattr(args, "topic", None):
        event["topics"] = [args.topic]
    if getattr(args, "summary", None):
        event["manual_summary"] = str(args.summary)
    if transcript_path:
        event["transcript_path_hash"] = hashlib.sha256(str(transcript_path).encode("utf-8")).hexdigest()
    return event


def event_queue_path(root: Path, event: dict[str, Any]) -> Path:
    return root / "queue" / f"{event['ts'][:10]}.jsonl"


def load_state(root: Path, event: dict[str, Any]) -> tuple[dict[str, Any], bool, Path]:
    path = state_path(root, event["harness"], event["native_session_id"])
    is_new = not path.exists()
    state = read_json(path, {})
    if not isinstance(state, dict):
        state = {}
        is_new = True
    return state, is_new, path


def update_state(root: Path, event: dict[str, Any], config: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    state, is_new, path = load_state(root, event)
    now = str(event["ts"])
    state.setdefault("schema_version", SCHEMA_VERSION)
    state.setdefault("harness", event["harness"])
    state.setdefault("native_session_id", event["native_session_id"])
    state.setdefault("llm_wiki_session_id", event["llm_wiki_session_id"])
    state.setdefault("started_at", now)
    state["last_seen_at"] = now
    state["cwd"] = event.get("cwd")
    state["transcript_path"] = event.get("transcript_path")
    state["model"] = event.get("model") or state.get("model")
    state["privacy"] = config.get("privacy", "redacted")
    state["raw_transcripts"] = bool(config.get("raw_transcripts", False))
    state["git_remote"] = git_value(event.get("cwd"), ["config", "--get", "remote.origin.url"])
    state["git_branch"] = git_value(event.get("cwd"), ["branch", "--show-current"])
    state["event_count"] = int(state.get("event_count") or 0) + 1
    if is_tool_event(event):
        state["tool_event_count"] = int(state.get("tool_event_count") or 0) + 1
    else:
        state.setdefault("tool_event_count", int(state.get("tool_event_count") or 0))
    topics = set(as_list(state.get("topics")))
    topics.update(str(item) for item in as_list(event.get("topics")))
    if topics:
        state["topics"] = sorted(topics)
    summaries = as_list(state.get("manual_summaries"))
    if event.get("manual_summary"):
        summaries.append(str(event["manual_summary"]))
        state["manual_summaries"] = summaries[-10:]
    if event.get("hook_event_name") == "PostCompact":
        state["last_compact_event"] = event.get("payload_preview")
    last_events = as_list(state.get("last_events"))
    last_events.append(
        {
            "ts": event.get("ts"),
            "hook_event_name": event.get("hook_event_name"),
            "tool_name": event.get("tool_name"),
            "turn_id": event.get("turn_id"),
            "trigger": event.get("trigger"),
        }
    )
    state["last_events"] = last_events[-MAX_LAST_EVENTS:]
    write_json(path, state)
    return state, is_new


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def is_tool_event(event: dict[str, Any]) -> bool:
    name = str(event.get("hook_event_name") or "")
    return bool(event.get("tool_name")) or name in {"PreToolUse", "PostToolUse", "PermissionRequest", "BeforeTool", "AfterTool"}


def should_write_digest(state: dict[str, Any], event: dict[str, Any], config: dict[str, Any], force: bool = False) -> tuple[bool, str]:
    if force:
        return True, str(event.get("trigger") or "manual")
    auto = config.get("auto_capture") if isinstance(config.get("auto_capture"), dict) else {}
    event_name = str(event.get("hook_event_name") or "")
    lower = event_name.lower().replace("_", "")
    if lower in {"precompact", "precompress"} and auto.get("pre_compact", True):
        return True, "pre-compact"
    if lower in {"postcompact", "postcompress"} and auto.get("post_compact", True):
        return True, "post-compact"
    if lower in {"sessionend", "afteragent"} and auto.get("session_end", True):
        return True, "session-end"
    if lower in {"stop", "stopfailure"} and auto.get("stop", True):
        return True, "stop"
    threshold = int(auto.get("tool_events") or 0)
    tool_count = int(state.get("tool_event_count") or 0)
    if threshold > 0 and is_tool_event(event) and tool_count > 0 and tool_count % threshold == 0:
        return True, f"tool-count-{threshold}"
    return False, ""


def yaml_string(value: Any) -> str:
    text = "" if value is None else str(value)
    if text == "":
        return '""'
    if re.fullmatch(r"[A-Za-z0-9_.:/@+ -]+", text):
        return json.dumps(text)
    return json.dumps(text)


def yaml_list(values: list[Any]) -> str:
    return "[" + ", ".join(yaml_string(item) for item in values) + "]"


def digest_summary(state: dict[str, Any], trigger: str) -> str:
    manual = as_list(state.get("manual_summaries"))
    if manual:
        return str(manual[-1])[:240]
    cwd = state.get("cwd") or "unknown cwd"
    return f"Automated {trigger} checkpoint for {state.get('llm_wiki_session_id')} in {cwd}."


def frontmatter_block(state: dict[str, Any], trigger: str, digest_file: Path) -> str:
    summary = digest_summary(state, trigger)
    topics = as_list(state.get("topics"))
    lines = [
        "---",
        f"title: {yaml_string('Session Digest: ' + str(state.get('llm_wiki_session_id')))}",
        "type: session-digest",
        f"schema_version: {SCHEMA_VERSION}",
        f"harness: {yaml_string(state.get('harness'))}",
        f"native_session_id: {yaml_string(state.get('native_session_id'))}",
        f"llm_wiki_session_id: {yaml_string(state.get('llm_wiki_session_id'))}",
        f"cwd: {yaml_string(state.get('cwd'))}",
        f"git_remote: {yaml_string(state.get('git_remote'))}",
        f"git_branch: {yaml_string(state.get('git_branch'))}",
        f"transcript_path: {yaml_string(state.get('transcript_path'))}",
        f"started_at: {yaml_string(state.get('started_at'))}",
        f"last_seen_at: {yaml_string(state.get('last_seen_at'))}",
        f"tool_event_count: {int(state.get('tool_event_count') or 0)}",
        f"event_count: {int(state.get('event_count') or 0)}",
        f"capture_trigger: {yaml_string(trigger)}",
        f"topics: {yaml_list(topics)}",
        "topic_candidates: []",
        f"privacy: {yaml_string(state.get('privacy') or 'redacted')}",
        f"raw_transcripts: {str(bool(state.get('raw_transcripts'))).lower()}",
        "promoted_to: []",
        f"summary: {yaml_string(summary)}",
        "---",
    ]
    return "\n".join(lines) + "\n"


def markdown_table(rows: list[tuple[str, str]]) -> str:
    out = ["| Field | Value |", "|---|---|"]
    for key, value in rows:
        safe = str(value or "").replace("|", "\\|").replace("\n", " ")
        out.append(f"| {key} | {safe} |")
    return "\n".join(out)


def render_digest(state: dict[str, Any], trigger: str, digest_file: Path) -> str:
    summary = digest_summary(state, trigger)
    last_events = as_list(state.get("last_events"))[-12:]
    event_lines = []
    for event in last_events:
        event_lines.append(
            f"- `{event.get('ts')}` — {event.get('hook_event_name')}"
            + (f" / {event.get('tool_name')}" if event.get("tool_name") else "")
        )
    if not event_lines:
        event_lines.append("- No hook events recorded yet.")

    manual = as_list(state.get("manual_summaries"))
    manual_lines = [f"- {item}" for item in manual[-5:]] or ["- None recorded."]

    body = f"""
# Session Digest: {state.get('llm_wiki_session_id')}

## Summary

{summary}

## Session Identity

{markdown_table([
        ('Harness', state.get('harness')),
        ('Native session ID', state.get('native_session_id')),
        ('llm-wiki session ID', state.get('llm_wiki_session_id')),
        ('CWD', state.get('cwd')),
        ('Git remote', state.get('git_remote')),
        ('Git branch', state.get('git_branch')),
        ('Transcript pointer', state.get('transcript_path')),
        ('Started at', state.get('started_at')),
        ('Last seen at', state.get('last_seen_at')),
        ('Capture trigger', trigger),
        ('Observed tool events', state.get('tool_event_count')),
        ('Observed total events', state.get('event_count')),
    ])}

## Manual Summaries

{chr(10).join(manual_lines)}

## Recent Observed Events

{chr(10).join(event_lines)}

## Distillation Notes

- This digest is an automated checkpoint generated from redacted hook metadata.
- Raw transcript text is not copied by default; use the transcript pointer only if the harness still owns a readable transcript and the user approves.
- Promote useful distilled learnings into a topic wiki with `llm-wiki-session promote`; do not treat this operational digest as canonical topic knowledge until promoted.

## Open Loops

- Review whether this session should be topic-tagged or promoted.
- If the session ended mid-task, use `llm-wiki-session rehydrate --session-id {state.get('llm_wiki_session_id')}` before continuing.
""".strip()
    return frontmatter_block(state, trigger, digest_file) + "\n" + body + "\n"


def write_digest(root: Path, state: dict[str, Any], trigger: str) -> Path:
    path = digest_path(root, str(state["harness"]), str(state["native_session_id"]), str(state.get("last_seen_at") or utc_now()))
    text = render_digest(state, trigger, path)
    atomic_write(path, text)
    state["last_digest_path"] = str(path)
    state["last_digest_at"] = utc_now()
    state["digest_count"] = int(state.get("digest_count") or 0) + 1
    write_json(state_path(root, str(state["harness"]), str(state["native_session_id"])), state)
    append_jsonl(
        root / "registry.jsonl",
        {
            "schema_version": SCHEMA_VERSION,
            "ts": utc_now(),
            "event": "digest_written",
            "llm_wiki_session_id": state.get("llm_wiki_session_id"),
            "harness": state.get("harness"),
            "native_session_id": state.get("native_session_id"),
            "digest_path": str(path),
            "capture_trigger": trigger,
            "cwd": state.get("cwd"),
            "topics": as_list(state.get("topics")),
        },
    )
    rebuild_indexes(root)
    return path


def rebuild_indexes(root: Path) -> None:
    by_cwd: dict[str, list[dict[str, Any]]] = {}
    by_topic: dict[str, list[dict[str, Any]]] = {}
    states: list[dict[str, Any]] = []
    for path in sorted((root / "state").glob("*/*.json")):
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(state, dict):
            continue
        states.append(state)
        record = {
            "llm_wiki_session_id": state.get("llm_wiki_session_id"),
            "harness": state.get("harness"),
            "native_session_id": state.get("native_session_id"),
            "last_seen_at": state.get("last_seen_at"),
            "last_digest_path": state.get("last_digest_path"),
        }
        cwd = str(state.get("cwd") or "")
        if cwd:
            by_cwd.setdefault(cwd, []).append(record)
        for topic in as_list(state.get("topics")):
            by_topic.setdefault(str(topic), []).append(record)
    write_json(root / "indexes" / "by-cwd.json", by_cwd)
    write_json(root / "indexes" / "by-topic.json", by_topic)
    write_json(root / "indexes" / "sessions.json", {"sessions": states})


def hook_output(event_name: str, context: str) -> None:
    if not context.strip():
        return
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": event_name,
                    "additionalContext": context,
                }
            },
            ensure_ascii=False,
        )
    )


def run_hook(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    config = load_config(root)
    if args.if_enabled and not config.get("enabled"):
        raise HookSkip()
    ensure_layout(root)
    raw = sys.stdin.read()
    payload: dict[str, Any]
    if raw.strip():
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid hook JSON input: {exc}") from exc
        if not isinstance(parsed, dict):
            raise SystemExit("hook JSON input must be an object")
        payload = parsed
    else:
        payload = {}
    event = normalize_event(args, payload, root)
    append_jsonl(event_queue_path(root, event), event)
    state, is_new = update_state(root, event, config)
    if is_new:
        append_jsonl(
            root / "registry.jsonl",
            {
                "schema_version": SCHEMA_VERSION,
                "ts": event["ts"],
                "event": "session_seen",
                "llm_wiki_session_id": event["llm_wiki_session_id"],
                "harness": event["harness"],
                "native_session_id": event["native_session_id"],
                "cwd": event.get("cwd"),
                "transcript_path": event.get("transcript_path"),
            },
        )
    write, trigger = should_write_digest(state, event, config, force=False)
    if write:
        write_digest(root, state, trigger)
    else:
        rebuild_indexes(root)

    event_name = str(event.get("hook_event_name") or "")
    rehydrate_cfg = config.get("rehydrate") if isinstance(config.get("rehydrate"), dict) else {}
    if event_name == "SessionStart" and rehydrate_cfg.get("session_start"):
        hook_output(event_name, build_rehydrate_context(root, cwd=event.get("cwd"), limit=3))
    elif event_name == "UserPromptSubmit" and rehydrate_cfg.get("user_prompt"):
        hook_output(event_name, build_rehydrate_context(root, cwd=event.get("cwd"), limit=3))
    return 0


def run_enable(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    ensure_layout(root)
    config = mode_config(args.mode)
    existing = load_config(root)
    if (root / "config.json").exists() and not args.force:
        config = merge_dict(existing, config)
    if args.tool_events is not None:
        config.setdefault("auto_capture", {})["tool_events"] = int(args.tool_events)
    config["enabled"] = args.mode != "off"
    write_json(root / "config.json", config)
    print(f"llm-wiki sessions {config['mode']}: {root}")
    print(f"enabled: {config['enabled']}")
    print("raw_transcripts: false")
    return 0


def run_disable(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    ensure_layout(root)
    config = load_config(root)
    config["enabled"] = False
    config["mode"] = "off"
    write_json(root / "config.json", config)
    print(f"llm-wiki sessions disabled: {root}")
    return 0


def manual_payload(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "session_id": args.session_id or f"manual-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}",
        "hook_event_name": "ManualCapture",
        "cwd": args.cwd or os.getcwd(),
        "transcript_path": args.transcript_path,
        "model": args.model,
        "manual_summary": args.summary,
    }


def run_capture(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    ensure_layout(root)
    config = load_config(root)
    payload = manual_payload(args)
    event = normalize_event(args, payload, root)
    append_jsonl(event_queue_path(root, event), event)
    state, is_new = update_state(root, event, config)
    if is_new:
        append_jsonl(
            root / "registry.jsonl",
            {
                "schema_version": SCHEMA_VERSION,
                "ts": event["ts"],
                "event": "session_seen",
                "llm_wiki_session_id": event["llm_wiki_session_id"],
                "harness": event["harness"],
                "native_session_id": event["native_session_id"],
                "cwd": event.get("cwd"),
                "transcript_path": event.get("transcript_path"),
            },
        )
    path = write_digest(root, state, "manual")
    print(str(path))
    return 0


def iter_states(root: Path) -> list[dict[str, Any]]:
    states = []
    for path in sorted((root / "state").glob("*/*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            states.append(data)
    return sorted(states, key=lambda item: str(item.get("last_seen_at") or ""), reverse=True)


def session_matches(state: dict[str, Any], args: argparse.Namespace) -> bool:
    if getattr(args, "harness", None) and state.get("harness") != args.harness:
        return False
    if getattr(args, "cwd", None) and state.get("cwd") != args.cwd:
        return False
    if getattr(args, "topic", None) and args.topic not in as_list(state.get("topics")):
        return False
    return True


def run_list(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    states = [state for state in iter_states(root) if session_matches(state, args)]
    if args.json:
        print(json.dumps({"sessions_root": str(root), "sessions": states}, indent=2, sort_keys=True))
        return 0
    print(f"llm-wiki sessions: {root}")
    print("| Session | Last seen | Tools | CWD | Digest |")
    print("|---|---:|---:|---|---|")
    for state in states[: args.limit]:
        print(
            "| {sid} | {last} | {tools} | {cwd} | {digest} |".format(
                sid=str(state.get("llm_wiki_session_id") or "").replace("|", "\\|"),
                last=str(state.get("last_seen_at") or ""),
                tools=int(state.get("tool_event_count") or 0),
                cwd=str(state.get("cwd") or "").replace("|", "\\|"),
                digest=str(state.get("last_digest_path") or ""),
            )
        )
    return 0


def find_session(root: Path, session_id: str) -> dict[str, Any] | None:
    for state in iter_states(root):
        if session_id in {state.get("llm_wiki_session_id"), state.get("native_session_id")}:
            return state
    return None


def split_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    raw = text[4:end]
    body = text[end + 5 :]
    data: dict[str, Any] = {}
    for line in raw.splitlines():
        if not line.strip() or ":" not in line or line.startswith(" "):
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            try:
                data[key.strip()] = json.loads(value)
            except json.JSONDecodeError:
                data[key.strip()] = []
        else:
            data[key.strip()] = value.strip('"')
    return data, body


def run_show(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    state = find_session(root, args.session_id)
    if not state:
        raise SystemExit(f"session not found: {args.session_id}")
    digest = state.get("last_digest_path")
    if not digest:
        raise SystemExit(f"session has no digest yet: {args.session_id}")
    path = Path(str(digest))
    if args.path_only:
        print(str(path))
    else:
        print(path.read_text(encoding="utf-8"))
    return 0


def build_rehydrate_context(root: Path, cwd: str | None = None, session_id: str | None = None, topic: str | None = None, limit: int = 3) -> str:
    candidates = iter_states(root)
    selected: list[dict[str, Any]] = []
    for state in candidates:
        if session_id and session_id not in {state.get("llm_wiki_session_id"), state.get("native_session_id")}:
            continue
        if topic and topic not in as_list(state.get("topics")):
            continue
        if cwd and not session_id and not topic and state.get("cwd") != cwd:
            continue
        if state.get("last_digest_path"):
            selected.append(state)
        if len(selected) >= limit:
            break
    if not selected:
        return ""
    lines = [
        "llm-wiki session context: review these distilled session digests before continuing.",
    ]
    for state in selected:
        lines.append(
            f"- {state.get('llm_wiki_session_id')} — {digest_summary(state, 'rehydrate')} "
            f"Digest: {state.get('last_digest_path')}"
        )
    lines.append("Do not treat session digests as canonical topic knowledge until promoted into a topic wiki.")
    return "\n".join(lines)


def run_rehydrate(args: argparse.Namespace) -> int:
    root = sessions_dir(resolve_hub(args))
    context = build_rehydrate_context(root, cwd=args.cwd, session_id=args.session_id, topic=args.topic, limit=args.limit)
    if not context:
        print("No matching session digests found.")
        return 1
    print(context)
    return 0


def read_registry(hub: Path) -> dict[str, Any]:
    path = hub / "wikis.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_registry_path(raw_path: str, hub: Path) -> Path:
    if raw_path in {".", "<HUB>", "HUB"}:
        return hub
    if raw_path.startswith("<HUB>/"):
        return hub / raw_path[len("<HUB>/") :]
    if raw_path.startswith("HUB/"):
        return hub / raw_path[len("HUB/") :]
    path = expand_leading_tilde(raw_path)
    if path.is_absolute():
        return path
    return hub / path


def topic_path(hub: Path, slug: str) -> Path:
    registry = read_registry(hub)
    entry = registry.get("wikis", {}).get(slug) if isinstance(registry.get("wikis"), dict) else None
    if isinstance(entry, dict) and entry.get("path"):
        return resolve_registry_path(str(entry["path"]), hub)
    return hub / "topics" / slug


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")[:80] or "session"


def append_topic_log(topic_root: Path, message: str) -> None:
    log = topic_root / "log.md"
    if log.exists():
        with log.open("a", encoding="utf-8") as handle:
            handle.write(f"\n## [{today()}] session | {message}\n")


def run_promote(args: argparse.Namespace) -> int:
    hub = resolve_hub(args)
    root = sessions_dir(hub)
    state = find_session(root, args.session_id)
    if not state:
        raise SystemExit(f"session not found: {args.session_id}")
    digest = state.get("last_digest_path")
    if not digest:
        raise SystemExit(f"session has no digest yet: {args.session_id}")
    digest_file = Path(str(digest))
    digest_text = digest_file.read_text(encoding="utf-8")
    fm, body = split_frontmatter(digest_text)
    topic_root = topic_path(hub, args.topic)
    notes = topic_root / "raw" / "notes"
    if not notes.exists():
        raise SystemExit(f"topic raw notes directory not found: {notes}")
    filename = f"{today()}-session-{slugify(str(state.get('harness')))}-{slugify(str(state.get('native_session_id')))}.md"
    dest = notes / filename
    if dest.exists() and not args.force:
        raise SystemExit(f"promotion note already exists: {dest}")
    summary = fm.get("summary") or digest_summary(state, "promote")
    promoted = textwrap.dedent(
        f"""
        ---
        title: {yaml_string('Session Digest Promotion: ' + str(state.get('llm_wiki_session_id')))}
        source: {yaml_string(str(digest_file))}
        type: notes
        ingested: {today()}
        tags: [session-digest, session-promotion, {yaml_string(args.topic)}]
        summary: {yaml_string(summary)}
        ---

        # Session Digest Promotion: {state.get('llm_wiki_session_id')}

        Source digest: [{digest_file.name}]({digest_file})

        This note promotes a distilled session checkpoint into the `{args.topic}` topic raw layer. It intentionally promotes the digest, not the raw transcript.

        {body.strip()}
        """
    ).strip() + "\n"
    atomic_write(dest, promoted)
    topics = set(as_list(state.get("topics")))
    topics.add(args.topic)
    state["topics"] = sorted(topics)
    promoted_to = as_list(state.get("promoted_to"))
    promoted_to.append(str(dest))
    state["promoted_to"] = sorted(set(str(item) for item in promoted_to))
    write_json(state_path(root, str(state["harness"]), str(state["native_session_id"])), state)
    rebuild_indexes(root)
    append_topic_log(topic_root, f"promoted session digest {state.get('llm_wiki_session_id')} → raw/notes/{filename}")
    print(str(dest))
    return 0


def run_status(args: argparse.Namespace) -> int:
    hub = resolve_hub(args)
    root = sessions_dir(hub)
    config = load_config(root)
    states = iter_states(root) if root.exists() else []
    report = {
        "hub": str(hub),
        "sessions_root": str(root),
        "enabled": bool(config.get("enabled")),
        "mode": config.get("mode"),
        "session_count": len(states),
        "config": config,
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"llm-wiki sessions: {root}")
        print(f"enabled: {report['enabled']}")
        print(f"mode: {report['mode']}")
        print(f"sessions: {report['session_count']}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="llm-wiki-session", description="Capture and rehydrate llm-wiki session context.")
    parser.add_argument("--hub", help="Override wiki hub path.")
    parser.add_argument("--local", action="store_true", help="Use .wiki/.sessions in the current directory.")
    sub = parser.add_subparsers(dest="command", required=True)

    enable = sub.add_parser("enable", help="Enable automated session capture in HUB/.sessions/config.json.")
    enable.add_argument("--mode", choices=sorted(MODE_CONFIGS), default="balanced")
    enable.add_argument("--tool-events", type=int, help="Override automated tool-event checkpoint threshold.")
    enable.add_argument("--force", action="store_true", help="Replace existing config instead of merging.")
    enable.set_defaults(func=run_enable)

    disable = sub.add_parser("disable", help="Disable automated session capture.")
    disable.set_defaults(func=run_disable)

    hook = sub.add_parser("hook", help="Record a harness hook event from JSON on stdin.")
    hook.add_argument("--harness", help="Harness name, e.g. codex, claude, opencode, gemini.")
    hook.add_argument("--event-name", help="Override hook event name.")
    hook.add_argument("--session-id", help="Override native session id.")
    hook.add_argument("--cwd", help="Override session cwd.")
    hook.add_argument("--topic", help="Attach a topic tag to this event/state.")
    hook.add_argument("--summary", help="Manual summary to append to state.")
    hook.add_argument("--trigger", help="Override capture trigger name.")
    hook.add_argument("--if-enabled", action="store_true", help="No-op unless .sessions/config.json has enabled=true.")
    hook.add_argument("--max-event-bytes", type=int, default=MAX_EVENT_PREVIEW_CHARS)
    hook.set_defaults(func=run_hook)

    capture = sub.add_parser("capture", help="Force a manual session digest checkpoint.")
    capture.add_argument("--harness", default="manual")
    capture.add_argument("--session-id", help="Native session id; defaults to manual timestamp.")
    capture.add_argument("--cwd", help="Session working directory; defaults to current directory.")
    capture.add_argument("--transcript-path", help="Transcript pointer to record without copying contents.")
    capture.add_argument("--model", help="Model/profile label to record.")
    capture.add_argument("--topic", help="Topic tag to attach to this digest.")
    capture.add_argument("--summary", help="Short manual summary for the digest.")
    capture.set_defaults(func=run_capture)

    list_cmd = sub.add_parser("list", help="List captured sessions.")
    list_cmd.add_argument("--harness", help="Filter by harness.")
    list_cmd.add_argument("--cwd", help="Filter by cwd.")
    list_cmd.add_argument("--topic", help="Filter by topic tag.")
    list_cmd.add_argument("--limit", type=int, default=20)
    list_cmd.add_argument("--json", action="store_true")
    list_cmd.set_defaults(func=run_list)

    show = sub.add_parser("show", help="Show a session digest.")
    show.add_argument("session_id", help="llm-wiki session id or native session id.")
    show.add_argument("--path-only", action="store_true")
    show.set_defaults(func=run_show)

    rehydrate = sub.add_parser("rehydrate", help="Print a compact context block from matching session digests.")
    rehydrate.add_argument("--session-id", help="llm-wiki session id or native session id.")
    rehydrate.add_argument("--cwd", help="Match sessions by cwd; defaults to current cwd.")
    rehydrate.add_argument("--topic", help="Match sessions by topic tag.")
    rehydrate.add_argument("--limit", type=int, default=3)
    rehydrate.set_defaults(func=run_rehydrate)

    promote = sub.add_parser("promote", help="Promote a session digest into a topic raw note.")
    promote.add_argument("session_id", help="llm-wiki session id or native session id.")
    promote.add_argument("--topic", required=True, help="Target topic slug.")
    promote.add_argument("--force", action="store_true")
    promote.set_defaults(func=run_promote)

    status = sub.add_parser("status", help="Show session capture status.")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=run_status)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except HookSkip:
        return 0
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    sys.exit(main())
