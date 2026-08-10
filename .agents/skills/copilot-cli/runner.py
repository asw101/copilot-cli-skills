#!/usr/bin/env python3
"""
SDK-mode runner for /copilot-sdk.

Drives `copilot -p ... --output-format json` and produces THREE artifacts:

  <id>.jsonl    Raw JSONL event stream from copilot. Full fidelity:
                thinking tokens, every tool call, every delta. Source of
                truth for replay.
  <id>.md       Human-readable transcript: rendered events only (tool
                calls, assistant messages, result line). Skip ephemeral.
  stdout        MINIMAL summary: the assistant's final message plus a
                one-line result. Designed to keep token cost low when an
                orchestrator reads it.

Pause/resume uses the .ask/.answer protocol from /copilot. When a
session id is captured, resume uses `copilot --resume <session>` so
Copilot keeps its full prior context.

Model defaults: gpt-5.6-sol with --reasoning-effort high and the
long_context (1M) context tier.
Overrides: COPILOT_MODEL, COPILOT_REASONING_EFFORT, COPILOT_CONTEXT_TIER.

Usage:
  runner.py <run_id> <transcript_md> <status> <taskfile>
"""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_MODEL = os.environ.get("COPILOT_MODEL", "gpt-5.6-sol")
DEFAULT_EFFORT = os.environ.get("COPILOT_REASONING_EFFORT", "high")

# Context window tier. "long_context" selects the 1M window on models that
# offer tiered context; "default" selects the standard window. The CLI
# validates this value and errors on anything else, so an unsupported tier
# fails loudly rather than silently downgrading. Set COPILOT_CONTEXT_TIER=""
# to omit the flag entirely.
DEFAULT_CONTEXT_TIER = os.environ.get("COPILOT_CONTEXT_TIER", "long_context")

# Models known to REJECT --reasoning-effort. Inverted from the prior
# allowlist so newly-shipped reasoning models "just work" without code
# changes. Override per-run with COPILOT_REASONING_EFFORT="" to force-drop
# the flag for any model.
THINKING_INCAPABLE = {
    "claude-haiku-4.5",
    "gpt-4.1",
    "gpt-5-mini",
    "gpt-5.4-mini",
}


def find_wrapper_prompt() -> str:
    p = Path(__file__).resolve().parent / "wrapper-prompt.md"
    return p.read_text() + "\n\n" if p.is_file() else ""


def render_event(evt: dict) -> str | None:
    """Markdown rendering of an event for the human transcript. Return
    None to hide noisy / ephemeral events from the .md (they're still in
    the .jsonl)."""
    t = evt.get("type", "")
    data = evt.get("data", {}) or {}

    if t == "user.message":
        return None

    if t == "assistant.message":
        content = (data.get("content") or "").rstrip()
        tool_reqs = data.get("toolRequests") or []
        parts = []
        if content:
            parts.append(content)
        for tr in tool_reqs:
            name = tr.get("name", "tool")
            args = tr.get("arguments") or tr.get("input") or {}
            preview = json.dumps(args, separators=(",", ":"))[:160]
            parts.append(f"  ↳ tool call: **{name}** `{preview}`")
        return "\n".join(parts) if parts else None

    if t == "assistant.thinking":
        thinking = (data.get("content") or "").rstrip()
        if thinking:
            return f"  💭 _{thinking[:300]}{'…' if len(thinking) > 300 else ''}_"
        return None

    if t == "tool.result":
        name = data.get("toolName") or data.get("name", "tool")
        output = (data.get("output") or "").rstrip()
        if not output:
            return f"  ↳ tool result: **{name}** (no output)"
        lines = output.splitlines()
        snippet = "\n".join(lines[:4])
        if len(lines) > 4:
            snippet += "\n    …"
        return f"  ↳ tool result: **{name}**\n```\n{snippet}\n```"

    if t == "assistant.turn_start":
        return f"\n— turn {data.get('turnId', '?')} —"

    if t == "result":
        usage = evt.get("usage") or {}
        cc = usage.get("codeChanges") or {}
        bits = []
        if "premiumRequests" in usage:
            bits.append(f"premium reqs: {usage['premiumRequests']}")
        if "sessionDurationMs" in usage:
            bits.append(f"duration: {usage['sessionDurationMs']/1000:.1f}s")
        added, removed = cc.get("linesAdded", 0), cc.get("linesRemoved", 0)
        if added or removed:
            bits.append(f"diff: +{added}/-{removed}")
        return f"\n_result — exitCode {evt.get('exitCode', '?')} — " + ", ".join(bits) + "_"

    # #6: don't silently drop unknown event types — protocol changes
    # should be visible to humans reading the .md. Render a single-line
    # placeholder; the .jsonl still has the full payload.
    if t:
        return f"  _· event: {t}_"
    return None


def run_copilot(
    prompt: str,
    md_fh,
    jsonl_fh,
    run_id: str,
    resume_session: str | None = None,
) -> tuple[int, str | None, str, dict]:
    """Spawn copilot, stream JSONL. Returns:
        (exit_code, session_id, final_assistant_text, result_event_or_{})"""
    cmd = ["copilot", "--allow-all-tools", "--output-format", "json"]
    if DEFAULT_MODEL:
        cmd += ["--model", DEFAULT_MODEL]
    if DEFAULT_EFFORT and DEFAULT_MODEL not in THINKING_INCAPABLE:
        cmd += ["--reasoning-effort", DEFAULT_EFFORT]
    if DEFAULT_CONTEXT_TIER:
        cmd += ["--context", DEFAULT_CONTEXT_TIER]
    if resume_session:
        cmd += ["--resume", resume_session]
    cmd += ["-p", prompt]

    env = os.environ.copy()
    env["COPILOT_RUN_ID"] = run_id

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
        bufsize=1,
    )

    session_id = None
    final_text = ""
    result_evt: dict = {}

    assert proc.stdout is not None
    for line in proc.stdout:
        raw = line.rstrip("\n")
        if not raw:
            continue
        jsonl_fh.write(raw + "\n")
        jsonl_fh.flush()

        try:
            evt = json.loads(raw)
        except json.JSONDecodeError:
            md_fh.write(raw + "\n")
            md_fh.flush()
            continue

        t = evt.get("type", "")
        if t == "result":
            result_evt = evt
            if evt.get("sessionId"):
                session_id = evt["sessionId"]
        elif t == "assistant.message":
            text = (evt.get("data", {}) or {}).get("content") or ""
            if text.strip():
                final_text = text  # track the last non-empty assistant message

        rendered = render_event(evt)
        if rendered is not None:
            md_fh.write(rendered + "\n")
            md_fh.flush()

    proc.wait()
    return proc.returncode, session_id, final_text.strip(), result_evt


def wait_for_answer(answer_path: Path, timeout_s: int = 86400) -> str | None:
    waited = 0
    while waited < timeout_s:
        if answer_path.is_file():
            return answer_path.read_text().rstrip("\n")
        time.sleep(5)
        waited += 5
    return None


def summary_line(usage: dict) -> str:
    """Standardized one-line summary across cli/acp/sdk. Missing fields
    are silently omitted."""
    bits = [f"exit {usage.get('exit_code', '?')}",
            f"{usage.get('backend', '?')}/{usage.get('model') or '?'}"]
    if usage.get("premium_requests") is not None:
        bits.append(f"premium {usage['premium_requests']}")
    inp, out = usage.get("input_tokens"), usage.get("output_tokens")
    if inp is not None or out is not None:
        bits.append(f"in/out: {inp or 0}/{out or 0}")
    cr, cw = usage.get("cache_read_tokens"), usage.get("cache_write_tokens")
    if cr or cw:
        bits.append(f"cache: {cr or 0}↑/{cw or 0}↓")
    if usage.get("reasoning_tokens"):
        bits.append(f"reasoning: {usage['reasoning_tokens']}")
    if usage.get("duration_s") is not None:
        bits.append(f"{usage['duration_s']:.1f}s")
    return "[" + " · ".join(bits) + "]"


def aggregate_usage(run_id: str, code: int, jsonl_path: Path, result_evt: dict) -> dict:
    """Collect everything the CLI/JSONL backend exposes about cost."""
    res = result_evt.get("usage") or {}
    total_out = 0
    model = None
    try:
        with open(jsonl_path) as f:
            for line in f:
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = evt.get("type", "")
                data = evt.get("data") or {}
                if t == "session.tools_updated" and data.get("model"):
                    model = data["model"]
                if t == "assistant.message":
                    total_out += data.get("outputTokens") or 0
                    if data.get("model"):
                        model = data["model"]
    except FileNotFoundError:
        pass

    return {
        "run_id": run_id,
        "backend": "cli",
        "model": model,
        "exit_code": code,
        "premium_requests": res.get("premiumRequests"),
        "duration_s": (res.get("sessionDurationMs") / 1000.0) if res.get("sessionDurationMs") else None,
        "duration_kind": "session",
        "input_tokens": None,
        "output_tokens": total_out or None,
        "cache_read_tokens": None,
        "cache_write_tokens": None,
        "reasoning_tokens": None,
        "lines_added": (res.get("codeChanges") or {}).get("linesAdded", 0),
        "lines_removed": (res.get("codeChanges") or {}).get("linesRemoved", 0),
    }


def main():
    if len(sys.argv) < 5:
        print("usage: runner.py <run_id> <transcript_md> <status> <taskfile>", file=sys.stderr)
        return 2

    run_id, transcript_p, status_p, taskfile_p = sys.argv[1:5]
    runs_dir = Path(transcript_p).parent
    transcript = Path(transcript_p)
    jsonl_path = runs_dir / f"{run_id}.jsonl"
    status = Path(status_p)
    taskfile = Path(taskfile_p)
    ask_path = runs_dir / f"{run_id}.ask"
    answer_path = runs_dir / f"{run_id}.answer"
    session_path = runs_dir / f"{run_id}.session"

    task = taskfile.read_text().rstrip("\n")
    wrapper = find_wrapper_prompt()
    prompt = wrapper + task

    def handle_sigterm(_signum, _frame):
        status.write_text("cancelled\n")
        with transcript.open("a") as f:
            f.write("\n_cancelled by signal_\n")
        sys.exit(143)

    signal.signal(signal.SIGTERM, handle_sigterm)

    md_fh = transcript.open("a")
    jsonl_fh = jsonl_path.open("a")
    try:
        code, session_id, final_text, result_evt = run_copilot(
            prompt, md_fh, jsonl_fh, run_id
        )
        if session_id:
            session_path.write_text(session_id + "\n")

        while ask_path.is_file():
            status.write_text("needs-input\n")
            md_fh.write(f"\n_paused — waiting on {answer_path}_\n")
            md_fh.flush()
            answer = wait_for_answer(answer_path)
            if answer is None:
                status.write_text("failed\n")
                md_fh.write("\n_timed out waiting for answer_\n")
                return 1

            ask_path.unlink(missing_ok=True)
            answer_path.unlink(missing_ok=True)
            status.write_text("running\n")
            md_fh.write(f"\n_resumed with answer: {answer}_\n")
            md_fh.flush()

            if session_id:
                resume_prompt = (
                    f"The user has answered your question:\n{answer}\n\nContinue."
                )
                code, new_session, final_text, result_evt = run_copilot(
                    resume_prompt, md_fh, jsonl_fh, run_id,
                    resume_session=session_id,
                )
                if new_session:
                    session_id = new_session
                    session_path.write_text(session_id + "\n")
            else:
                resumed_prompt = (
                    wrapper + task +
                    f"\n\n[The user has answered your previous question:]\n{answer}\n\nContinue."
                )
                code, session_id, final_text, result_evt = run_copilot(
                    resumed_prompt, md_fh, jsonl_fh, run_id
                )
                if session_id:
                    session_path.write_text(session_id + "\n")

        status.write_text("done\n" if code == 0 else "failed\n")
        md_fh.write("\n_done_\n" if code == 0 else f"\n_failed (exit {code})_\n")

        # Aggregate per-task usage; write <id>.usage.json and a summary
        # block into the .md transcript.
        usage = aggregate_usage(run_id, code, jsonl_path, result_evt)
        usage_path = runs_dir / f"{run_id}.usage.json"
        usage_path.write_text(json.dumps(usage, indent=2) + "\n")
        md_fh.write(f"\n## Usage\n\n```\n{summary_line(usage)}\n```\n")
        md_fh.flush()

        # MINIMAL stdout (what the orchestrator sees). Final assistant
        # text + one-line summary. Full transcript stays on disk.
        if final_text:
            print(final_text)
        print(summary_line(usage))
        return code if code != 0 else 0
    finally:
        md_fh.close()
        jsonl_fh.close()


if __name__ == "__main__":
    sys.exit(main())
