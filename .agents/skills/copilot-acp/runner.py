#!/usr/bin/env python3
"""
ACP runner for /copilot-acp — type-safe edition using the official
agent-client-protocol Python SDK (`pip install agent-client-protocol`).

Replaces the prior hand-rolled JSON-RPC client. Same artifact contract
as /copilot-cli and /copilot-sdk so check.sh / cancel.sh stay shared.

Args:
  runner.py <run_id> <transcript_md> <status> <taskfile>

Writes:
  <id>.jsonl    raw event stream (one JSON object per event, our own shape)
  <id>.md       rendered transcript
  <id>.status   running | done | failed | cancelled
  <id>.session  Copilot session id
  <id>.usage.json   standardized usage block (mostly nulls — ACP doesn't
                    surface token data)
"""
from __future__ import annotations

import asyncio
import json
import os
import signal
import sys
import time
from pathlib import Path

import acp


DEFAULT_MODEL = os.environ.get("COPILOT_MODEL", "gpt-5.6-sol")
# ACP server caps reasoning effort per-model and rejects unsupported values.
# Config is applied best-effort below: a rejected key is written to the
# transcript and the run continues on the server default, so setting this
# is safe even where the server disagrees.
DEFAULT_EFFORT = os.environ.get("COPILOT_REASONING_EFFORT", "high")
# NOTE: there is deliberately no context-tier setting here. The ACP server
# exposes exactly four config options — mode, model, reasoning_effort,
# allow_all — and rejects 'context_tier' with "Unknown config option".
# ACP sessions therefore always run at the default context window; use the
# cli or sdk backend when the 1M (long_context) tier is required.


def summary_line(usage: dict) -> str:
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


class CopilotClient(acp.Client):
    """ACP client. We're driving Copilot (the agent), so we implement the
    callbacks the agent might invoke against us: streaming session
    updates and permission requests."""

    def __init__(self, md_fh, jsonl_fh):
        self.md_fh = md_fh
        self.jsonl_fh = jsonl_fh
        self.agent_text: list[str] = []
        # #8: buffer thought chunks. Flush by *gap* (idle time) and on
        # paragraph break, not on every "." — otherwise "e.g." flushes
        # mid-thought and the final chunk is lost if it has no terminal
        # punctuation. The watchdog task in run() drives gap-flushing.
        self._thought_buf: list[str] = []
        self._thought_last_ts: float = 0.0
        # Tokens — none of these will actually fire today; ACP server
        # doesn't surface usage, but the SDK schema includes UsageUpdate
        # so we wire it up speculatively.
        self.input_tokens: int | None = None
        self.output_tokens: int | None = None
        self.cache_read: int | None = None
        self.cache_write: int | None = None
        # #9: remember tool titles by id so ToolCallUpdate/Progress can
        # render the same name as the original ToolCallStart.
        self._tool_titles: dict[str, str] = {}

    def _flush_thought(self):
        if self._thought_buf:
            text = "".join(self._thought_buf).strip()
            if text:
                self.md_fh.write(f"\n💭 _{text}_\n")
                self.md_fh.flush()
            self._thought_buf = []

    async def session_update(self, session_id, update, **_):
        kind = type(update).__name__
        try:
            payload = update.model_dump(mode="json", by_alias=True)
        except Exception:
            payload = {"_repr": repr(update)}
        self.jsonl_fh.write(json.dumps({"kind": kind, "data": payload}) + "\n")
        self.jsonl_fh.flush()

        # Render the interesting kinds.
        if kind == "AgentMessageChunk":
            text = getattr(getattr(update, "content", None), "text", None)
            if text:
                self.md_fh.write(text)
                self.md_fh.flush()
                self.agent_text.append(text)
        elif kind == "AgentThoughtChunk":
            text = getattr(getattr(update, "content", None), "text", None)
            if text:
                self._thought_buf.append(text)
                self._thought_last_ts = time.monotonic()
                # Flush only on hard paragraph boundary. Gap-based flush
                # is driven by the watchdog task in run().
                if "\n\n" in text:
                    self._flush_thought()
        elif kind in ("ToolCallStart", "ToolCallUpdate", "ToolCallProgress"):
            self._flush_thought()
            tool_id = getattr(update, "tool_call_id", "") or ""
            title = getattr(update, "title", None)
            if title:
                self._tool_titles[tool_id] = title
            else:
                title = self._tool_titles.get(tool_id) or getattr(update, "kind", "tool") or "tool"
            status = getattr(update, "status", None)
            if kind == "ToolCallStart":
                raw_input = getattr(update, "raw_input", None)
                preview = ""
                if raw_input is not None:
                    try:
                        s = json.dumps(raw_input, separators=(",", ":"))
                    except Exception:
                        s = repr(raw_input)
                    if len(s) > 160:
                        s = s[:160] + "…"
                    preview = f" `{s}`"
                self.md_fh.write(f"\n  ↳ tool call: **{title}**{preview}\n")
            elif status in ("completed", "failed"):
                # #9: render tool result on terminal status.
                content = getattr(update, "content", None) or []
                snippet = ""
                for item in content:
                    text = getattr(getattr(item, "content", None), "text", None) or getattr(item, "text", None)
                    if text:
                        snippet += text
                        if len(snippet) > 400:
                            break
                snippet = snippet.strip()
                if snippet:
                    lines = snippet.splitlines()[:4]
                    body = "\n".join(lines)
                    if len(snippet.splitlines()) > 4:
                        body += "\n    …"
                    self.md_fh.write(
                        f"  ↳ tool result: **{title}** ({status})\n```\n{body}\n```\n"
                    )
                else:
                    self.md_fh.write(f"  ↳ tool result: **{title}** ({status})\n")
            self.md_fh.flush()
        elif kind == "UsageUpdate":
            # Speculative — copilot --acp doesn't emit these today, but
            # if it ever does, we'll pick up the typed fields.
            self.input_tokens = getattr(update, "input_tokens", None) or self.input_tokens
            self.output_tokens = getattr(update, "output_tokens", None) or self.output_tokens
            self.cache_read = getattr(update, "cache_read_tokens", None) or self.cache_read
            self.cache_write = getattr(update, "cache_write_tokens", None) or self.cache_write
        elif kind in ("AvailableCommandsUpdate", "ConfigOptionUpdate",
                       "CurrentModeUpdate", "SessionInfoUpdate"):
            pass  # session bootstrap noise — keep out of .md, still in .jsonl

    async def request_permission(self, options, session_id, tool_call, **_):
        # Auto-approve so non-interactive runs make progress. Prefer an
        # "allow_always" / "allow_once" option, else the first one.
        chosen = None
        for opt in options:
            kind = getattr(opt, "kind", None)
            if kind in ("allow_always", "allow_once"):
                chosen = opt
                break
        if chosen is None and options:
            chosen = options[0]
        outcome = acp.schema.PermissionRequestOutcomeSelected(
            outcome="selected", optionId=chosen.option_id,
        )
        return acp.RequestPermissionResponse(outcome=outcome)

    # The remaining Client methods (terminals, file I/O) we don't need;
    # the Protocol-based class will raise NotImplementedError if the agent
    # tries them, which is fine — they're not part of our common path.


async def run(run_id: str, transcript: Path, status: Path, taskfile: Path):
    runs_dir = transcript.parent
    jsonl_path = runs_dir / f"{run_id}.jsonl"
    session_path = runs_dir / f"{run_id}.session"
    usage_path = runs_dir / f"{run_id}.usage.json"
    ask_path = runs_dir / f"{run_id}.ask"
    answer_path = runs_dir / f"{run_id}.answer"

    task = taskfile.read_text().rstrip("\n")
    started = time.time()

    md_fh = transcript.open("a")
    jl_fh = jsonl_path.open("a")
    client = CopilotClient(md_fh, jl_fh)
    session_id: str | None = None
    stop_reason: str | None = None
    ok = False

    # #8: gap-based thought-flush watchdog. Every 0.5s, if the buffer has
    # been idle for >= 1.5s, flush it.
    async def thought_watchdog():
        try:
            while True:
                await asyncio.sleep(0.5)
                if client._thought_buf and (
                    time.monotonic() - client._thought_last_ts >= 1.5
                ):
                    client._flush_thought()
        except asyncio.CancelledError:
            client._flush_thought()
            raise

    async def wait_for_answer() -> str | None:
        # Poll the .answer file for up to 24h.
        for _ in range(17280):
            if answer_path.is_file():
                return answer_path.read_text().rstrip("\n")
            await asyncio.sleep(5)
        return None

    watchdog_task = None
    try:
        async with acp.spawn_agent_process(
            client, "copilot", "--acp",
            env=os.environ.copy(),
        ) as (conn, _proc):
            watchdog_task = asyncio.create_task(thought_watchdog())
            await conn.initialize(protocol_version=acp.PROTOCOL_VERSION)
            new_resp = await conn.new_session(cwd=os.getcwd(), mcp_servers=[])
            session_id = new_resp.session_id
            session_path.write_text(session_id + "\n")
            md_fh.write(f"_session: {session_id}_\n")
            md_fh.flush()

            # Apply session config. These are best-effort — if the server
            # rejects a key (e.g. unsupported), we surface and continue.
            cfg_settings = [("model", DEFAULT_MODEL), ("allow_all", "on")]
            if DEFAULT_EFFORT:
                cfg_settings.append(("reasoning_effort", DEFAULT_EFFORT))
            for cfg_id, value in cfg_settings:
                try:
                    await conn.set_config_option(
                        config_id=cfg_id, session_id=session_id, value=value
                    )
                except Exception as e:
                    md_fh.write(f"_config {cfg_id}={value!r} rejected: {e}_\n")

            prompt_resp = await conn.prompt(
                prompt=[acp.text_block(task)],
                session_id=session_id,
            )
            stop_reason = prompt_resp.stop_reason
            client._flush_thought()

            # #7: pause-for-input loop. If the task wrote an .ask file,
            # wait for .answer, then resume the same session with it.
            while ask_path.is_file():
                status.write_text("needs-input\n")
                md_fh.write(f"\n_paused — waiting on {answer_path}_\n")
                md_fh.flush()
                answer = await wait_for_answer()
                if answer is None:
                    status.write_text("failed\n")
                    md_fh.write("\n_timed out waiting for answer_\n")
                    md_fh.flush()
                    return
                ask_path.unlink(missing_ok=True)
                answer_path.unlink(missing_ok=True)
                status.write_text("running\n")
                md_fh.write(f"\n_resumed with answer: {answer}_\n")
                md_fh.flush()

                resume = (
                    f"The user has answered your question:\n{answer}\n\nContinue."
                )
                prompt_resp = await conn.prompt(
                    prompt=[acp.text_block(resume)],
                    session_id=session_id,
                )
                stop_reason = prompt_resp.stop_reason
                client._flush_thought()
            ok = True
    finally:
        if watchdog_task is not None:
            watchdog_task.cancel()
            try:
                await watchdog_task
            except (asyncio.CancelledError, Exception):
                pass
        usage = {
            "run_id": run_id,
            "backend": "acp",
            "model": DEFAULT_MODEL,
            "exit_code": 0 if ok else 1,
            "premium_requests": None,
            # #10: explicit about units — ACP doesn't surface API time,
            # so this is wall-clock from runner start. Callers (e.g.
            # usage.sh) should consult `duration_kind` to compare apples
            # to apples with CLI's session-duration field.
            "duration_s": time.time() - started,
            "duration_kind": "wall_clock",
            "input_tokens": client.input_tokens,
            "output_tokens": client.output_tokens,
            "cache_read_tokens": client.cache_read,
            "cache_write_tokens": client.cache_write,
            "reasoning_tokens": None,
            "stop_reason": stop_reason,
            "note": ("ACP server (copilot --acp) does not surface per-turn "
                     "token data via session/update.UsageUpdate today; "
                     "duration_s is wall-clock, not API time."),
        }
        usage_path.write_text(json.dumps(usage, indent=2) + "\n")

        md_fh.write(f"\n_prompt complete — stopReason: {stop_reason}_\n")
        md_fh.write(f"\n## Usage\n\n```\n{summary_line(usage)}\n```\n")
        md_fh.flush()
        md_fh.close()
        jl_fh.close()
        status.write_text("done\n" if ok else "failed\n")

        final = "".join(client.agent_text).strip()
        if final:
            print(final)
        print(summary_line(usage))


def main():
    if len(sys.argv) < 5:
        print("usage: runner.py <run_id> <transcript_md> <status> <taskfile>",
              file=sys.stderr)
        return 2

    run_id, transcript_p, status_p, taskfile_p = sys.argv[1:5]
    transcript = Path(transcript_p)
    status = Path(status_p)
    taskfile = Path(taskfile_p)

    def handle_sigterm(_signum, _frame):
        status.write_text("cancelled\n")
        with transcript.open("a") as f:
            f.write("\n_cancelled by signal_\n")
        sys.exit(143)

    signal.signal(signal.SIGTERM, handle_sigterm)

    try:
        asyncio.run(run(run_id, transcript, status, taskfile))
    except Exception as e:
        status.write_text("failed\n")
        with transcript.open("a") as f:
            f.write(f"\n_runner crashed: {type(e).__name__}: {e}_\n")
        print(f"[failed · {type(e).__name__}: {e}]", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
