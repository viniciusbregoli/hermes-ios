"""delegate_tiered: delegate_task with a per-task model tier (light, standard, heavy).

Tier routes live in config.yaml under ``delegation.tiers.<tier>``. Each entry takes the same keys as
the ``delegation`` section itself (model, provider, base_url, api_mode, reasoning_effort,
request_overrides, fallback_providers). An empty or missing entry inherits, exactly like delegate_task.
"""

import contextvars
import copy
import inspect
import json
import logging

logger = logging.getLogger(__name__)

TOOL_NAME = "delegate_tiered"
TIERS = ("light", "standard", "heavy")
# Keys that choose the child's route. A tier that sets any of them replaces all of them, so a
# delegation.base_url (or provider) can never leak onto a tier pinned somewhere else.
_ROUTE_KEYS = ("model", "provider", "base_url", "api_key", "api_mode", "command", "args")

DESCRIPTION = (
    "Same as delegate_task, but every task picks a model tier, so cheap work runs on a lighter model and "
    "hard work on a stronger one. Prefer this over delegate_task whenever the tasks differ in difficulty, "
    "or when a single task is clearly trivial or clearly hard.\n\n"
    "Tiers:\n"
    "- light: quick lookups, listing or searching files, summarizing short text, simple web lookups, "
    "formatting or converting data.\n"
    "- heavy: debugging, multi-file code changes, architecture or design work, deep research, and anything "
    "risky or hard to undo.\n"
    "- standard: everything else (the same model delegate_task uses).\n\n"
    "All delegate_task rules apply: children know nothing of this conversation, so pass everything they "
    "need in 'context'; results come back the same way (in chat sessions they arrive as a new message "
    "between your turns, one per tier used); child summaries are self-reports, verify side effects. To "
    "list, steer or stop running children use delegate_task with action=list/steer/stop."
)


def _task_properties() -> dict:
    """delegate_task's own task fields (so both tools stay in sync) plus ``tier``."""
    props = {
        "goal": {"type": "string", "description": "What this subagent should accomplish. Be specific and "
                 "self-contained: it knows nothing about your conversation."},
        "context": {"type": "string", "description": "Everything this child needs: file paths, errors, "
                    "constraints, output language."},
    }
    try:
        from tools.delegate_tool import DELEGATE_TASK_SCHEMA
        props = copy.deepcopy(DELEGATE_TASK_SCHEMA["parameters"]["properties"]["tasks"]["items"]["properties"])
        props.pop("group", None)  # only meaningful with delegation.independent_completions
    except Exception:
        logger.debug("delegate-tiers: delegate_task schema unavailable, using minimal task fields", exc_info=True)
    props["tier"] = {
        "type": "string", "enum": list(TIERS),
        "description": "Model tier for this task: light (trivial), standard (default), heavy (hard or risky).",
    }
    return props


SCHEMA = {
    "name": TOOL_NAME,
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "tasks": {
                "type": "array", "minItems": 1,
                "items": {"type": "object", "properties": {}, "required": ["goal", "tier"]},
                "description": "The tasks; each entry spawns one subagent on its tier's model. Tasks of the "
                               "same tier run in parallel as one batch.",
            },
        },
        "required": ["tasks"],
    },
}


def _install_config_override(delegate_tool) -> contextvars.ContextVar:
    """Make delegate_tool's ``_load_config`` return a tier's merged config while a ContextVar is set.

    Hermes reads the delegation section through this one function for the child's route, credentials,
    fallback chain AND reasoning effort (the per-call ``credentials_cfg`` hook skips reasoning_effort),
    so scoping it per call makes each tier spawn exactly like delegate_task with that config. The
    ContextVar keeps it local to this tool call: other sessions delegating concurrently are untouched.
    The variable lives on the wrapper so a plugin reload reuses it instead of wrapping twice.
    """
    current = delegate_tool._load_config
    var = getattr(current, "_delegate_tiers_var", None)
    if var is not None:
        return var
    var = contextvars.ContextVar("delegate_tiers_cfg", default=None)

    def _load_config():
        override = var.get()
        return override if override is not None else current()

    _load_config._delegate_tiers_var = var
    _load_config._delegate_tiers_original = current
    delegate_tool._load_config = _load_config
    return var


def tier_config(delegation_cfg: dict, tier: str) -> dict:
    """The delegation section as delegate_task should see it for *tier*."""
    base = dict(delegation_cfg or {})
    tiers = base.pop("tiers", None)
    entry = tiers.get(tier) if isinstance(tiers, dict) else None
    entry = entry if isinstance(entry, dict) else {}
    if any(entry.get(k) for k in _ROUTE_KEYS):
        for k in _ROUTE_KEYS:
            base.pop(k, None)
    base.update(entry)
    return base


def group_by_tier(tasks: list) -> dict:
    """{tier: [(original_index, task_without_tier), ...]} in TIERS order; unknown tiers become standard."""
    groups: dict = {}
    for i, task in enumerate(tasks):
        tier = str(task.get("tier") or "standard").strip().lower()
        groups.setdefault(tier if tier in TIERS else "standard", []).append(
            (i, {k: v for k, v in task.items() if k != "tier"}))
    return {t: groups[t] for t in TIERS if t in groups}


def _parse(raw):
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return raw


def _active_parent(parent_agent):
    if parent_agent is not None:
        return parent_agent
    try:
        from agent.subagent_lifecycle import get_active_subagent_parent
        return get_active_subagent_parent()
    except ImportError:
        return None


def _stock_fallback(tasks: list, parent, reason: str) -> str:
    """Hermes internals moved: run everything through the stock delegate_task handler instead."""
    logger.warning("delegate-tiers: falling back to delegate_task, tiers ignored (%s)", reason)
    from tools.registry import registry
    plain = [{k: v for k, v in t.items() if k != "tier"} for t in tasks]
    raw = registry.dispatch("delegate_task", {"tasks": plain}, parent_agent=parent)
    return json.dumps({"note": f"Tiers were ignored and every task ran on the default delegation model ({reason}).",
                       "result": _parse(raw)}, ensure_ascii=False)


def handle(args: dict, parent_agent=None, **_kwargs) -> str:
    parent = _active_parent(parent_agent)
    if parent is None:
        return json.dumps({"error": f"{TOOL_NAME} needs a live agent session."})
    tasks = args.get("tasks")
    if not isinstance(tasks, list) or not tasks or not all(isinstance(t, dict) for t in tasks):
        return json.dumps({"error": "tasks must be a non-empty array of objects."})

    try:
        import tools.delegate_tool as delegate_tool
        inspect.signature(delegate_tool.delegate_task).bind(tasks=[], background=True, parent_agent=parent)
        original_loader = getattr(delegate_tool._load_config, "_delegate_tiers_original", delegate_tool._load_config)
        var = _install_config_override(delegate_tool)
        strip_hidden = delegate_tool._strip_model_hidden_task_fields
    except (ImportError, AttributeError, TypeError) as exc:
        return _stock_fallback(tasks, parent, f"{type(exc).__name__}: {exc}")

    # Same rule as run_agent._dispatch_delegate_task: top-level calls run in the background, an
    # orchestrator child (depth > 0) waits for its workers inside its own turn.
    background = not getattr(parent, "_delegate_depth", 0) > 0
    delegation_cfg = original_loader()
    out = []
    for tier, items in group_by_tier(tasks).items():
        cfg = tier_config(delegation_cfg, tier)
        token = var.set(cfg)
        try:
            raw = delegate_tool.delegate_task(
                tasks=strip_hidden([task for _, task in items]), background=background, parent_agent=parent)
        finally:
            var.reset(token)
        out.append({
            "tier": tier, "model": cfg.get("model") or getattr(parent, "model", None),
            "task_indices": [i for i, _ in items], "result": _parse(raw),
        })
    return json.dumps({"tiers": out}, ensure_ascii=False)


def _exempt_from_tool_deadline() -> None:
    """Synchronous runs (one-shot CLI, cron, orchestrator children) block for the whole batch, like
    delegate_task, which Hermes exempts from the generic sequential tool deadline for that reason."""
    try:
        import agent.tool_executor as tool_executor
        tool_executor._SEQUENTIAL_DEADLINE_EXEMPT_TOOLS = tool_executor._SEQUENTIAL_DEADLINE_EXEMPT_TOOLS | {TOOL_NAME}
    except Exception:
        logger.debug("delegate-tiers: could not exempt %s from the tool deadline", TOOL_NAME, exc_info=True)


def register(ctx):
    schema = copy.deepcopy(SCHEMA)
    schema["parameters"]["properties"]["tasks"]["items"]["properties"] = _task_properties()
    _exempt_from_tool_deadline()
    ctx.register_tool(
        name=TOOL_NAME, toolset="delegation", schema=schema, handler=handle,
        check_fn=lambda: True,
    )
