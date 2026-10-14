# delegate-tiers

Hermes Agent plugin that adds a `delegate_tiered` tool to the `delegation` toolset. It works like
`delegate_task`, but every task carries a `tier` (`light`, `standard` or `heavy`) and runs on that tier's
model. The tool description tells the agent when to use each tier and to prefer this tool over
`delegate_task` when tasks differ in difficulty. `delegate_task` stays untouched and available.

Children are real Hermes subagents: tasks of the same tier are spawned through `delegate_task` itself,
so they emit the same `subagent.*` events, show up in `delegate_task action=list/steer/stop`, and follow
the same background and notification rules (one result message per tier used). If Hermes internals it
relies on change, the tool falls back to the stock `delegate_task` handler and says the tiers were ignored.

## Config

Tier routes live in `config.yaml` under `delegation.tiers`. Each entry accepts the same keys as the
`delegation` section (`model`, `provider`, `base_url`, `api_mode`, `reasoning_effort`,
`request_overrides`, `fallback_providers`). An empty entry inherits the parent model, exactly like
`delegate_task`.

```yaml
delegation:
  tiers:
    light:
      provider: openai-codex
      model: gpt-6-luna
      reasoning_effort: low
      fallback_providers:
        - provider: copilot
          model: gpt-6-luna
        - provider: openrouter
          model: openai/gpt-6-luna
    standard: {}
    heavy:
      provider: openai-codex
      model: gpt-6-astra
      reasoning_effort: high
      fallback_providers:
        - provider: copilot
          model: gpt-6-astra
        - provider: openrouter
          model: openai/gpt-6-astra
```

The dashboard REST API reads and writes the key as is. `PUT /api/config` deep-merges the body over the
file, so a partial body edits one tier and keeps the others (lists such as `fallback_providers` are
replaced whole):

```json
{"config": {"delegation": {"tiers": {"light": {"model": "gpt-6-luna", "reasoning_effort": "low"}}}}}
```

`GET /api/config` returns it under `delegation.tiers`. Add `?profile=<name>` for a bot profile.

### Subscription first

Tiers should run on flat-rate subscription providers and only reach pay-per-token APIs when the
subscription is unavailable. Hermes classifies billing in `agent.usage_pricing.resolve_billing_route()`:

- `subscription_included`: covered by a subscription (`openai-codex`). First choice.
- `unknown` with no per-token price in `hermes_cli.models_pricing.get_pricing_for_provider()`: plan-based
  providers Hermes does not meter (`copilot`, the `zai` coding plan). Second choice.
- `official_models_api` / `official_docs_snapshot`, or any provider with per-token pricing
  (`openrouter`, `nous` API, direct API keys): last resort, only as a fallback entry.

Put the subscription model in the tier itself and the API model only in `fallback_providers`. Hermes
switches to the next fallback entry eagerly on rate-limit and billing/quota errors, and after retries on
timeouts or overload; it does not use fallbacks as a first choice. A tier that pins a model never
inherits the parent's fallback chain, so list it explicitly.

## Install

Plugins are per Hermes home, so copy the plugin into every profile that should have it and enable it
there (the main home and each `~/.hermes/profiles/<bot>` whose `platform_toolsets` include `delegation`):

```sh
cp -r server/delegate-tiers ~/.hermes/plugins/
cp -r server/delegate-tiers ~/.hermes/profiles/<bot>/plugins/
```

Then add `delegate-tiers` to `plugins.enabled` in each of those `config.yaml` files (back them up first),
leave `plugins.entries.delegate-tiers.allow_tool_override` unset or `false` (the plugin overrides
nothing), and add `delegation.tiers` as above. Check it with `hermes plugins doctor delegate-tiers`.

Restart the long-running services while no agent is busy (`active_agents` is 0 in
`curl -s http://127.0.0.1:9119/api/status`):

```sh
systemctl --user restart hermes-dashboard.service hermes-gateway.service
```
