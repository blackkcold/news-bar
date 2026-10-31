#!/usr/bin/env python3
"""Generate the OpenCode Go/Zen price catalog.

The model list is the source of truth for prices; the monthly Go allowances
come from https://opencode.ai/docs/console/go (they are plan terms, not model
metadata). Re-run this after OpenCode changes its catalog:

    python3 scripts/generate-opencode-prices.py

The output is checked in so the app can price a model before the network is
available and so a catalog change is visible in review.
"""

from __future__ import annotations

import json
import urllib.request
from datetime import date
from pathlib import Path

ZEN_URL = "https://opencode.ai/inference/v1/models"
GO_URL = "https://opencode.ai/inference/go/v1/models"
OUTPUT = Path(__file__).resolve().parent.parent / "Sources/NewsBar/Models/AIPriceCatalog+OpenCode.swift"
UPDATED_AT = date.today().isoformat()

# https://opencode.ai/docs/console/go#usage-limits — USD of monthly allowance.
# None means unlimited (the promotional free models).
GO_ALLOWANCES: dict[str, tuple[float | None, float | None, float | None]] = {
    "glm-5.3-flash": (60, 180, 65),
    "glm-5.3": (15, 120, 20),
    "glm-5.2": (60, 180, 65),
    "kimi-k3.1-pro": (15, 60, 20),
    "kimi-k3": (15, 60, 20),
    "kimi-k2.7-code": (60, 180, 65),
    "longcat-2.0": (60, 240, 65),
    "step-5-preview": (15, 60, 20),
    "beam-free": (None, None, None),
    "iceman-contributor-free": (None, None, None),
    "mimo-v2.6-flash": (60, 120, 65),
    "mimo-v2.6-pro": (15, 60, 20),
    "mimo-v2.5": (60, 120, 65),
    "mimo-v2.5-pro": (15, 60, 20),
    "minimax-m3.1-flash": (20, 80, 25),
    "minimax-m3": (60, 180, 65),
    "muse-spark-1.3-contributor": (60, 120, 65),
    "muse-spark-1.2-contributor": (60, 120, 65),
    "qwen3.8-max": (15, 60, 20),
    "qwen3.8-flash": (30, 90, 35),
    "qwen3.7-plus": (60, 180, 65),
    "deepseek-v4.1-flash": (100, 200, 105),
    "deepseek-v4-pro": (15, 60, 20),
    "hy4-preview": (30, 120, 35),
    "hy3": (60, 240, 65),
    "grok-4.7": (15, 60, 20),
    "gpt-6-luna": (15, 60, 20),
    "gpt-5.6-luna": (15, 60, 20),
    "claude-haiku-5-5": (15, 60, 20),
    "gemini-4-argon": (30, 120, 35),
}

# Go's DeepSeek prices double during peak hours. The reservation must use the
# peak price so a budget is never under-estimated; the response's allowance
# corrects the settled amount.
GO_PEAK_MODELS = {"deepseek-v4.1-flash", "deepseek-v4-pro"}


def fetch(url: str) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "NewsBar-price-generator/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def max_price(base: float | int | None, overrides: list[dict] | None) -> float:
    values = [float(base or 0)]
    for override in overrides or []:
        values.append(float(override.get("price") or 0))
    return max(values)


def prices(model: dict, provider: str) -> tuple[float, float, float | None, float | None]:
    text = (model.get("cost") or {}).get("text") or {}
    source = text.get("input") or {}
    output = text.get("output") or {}
    input_price = max_price(source.get("price"), source.get("overrides"))
    output_price = max_price(output.get("price"), output.get("overrides"))

    input_cache = source.get("cache")
    cache_read_values: list[float] = []
    cache_write_values: list[float] = []
    if input_cache:
        if input_cache.get("read") is not None:
            cache_read_values.append(float(input_cache["read"]))
        if input_cache.get("write") is not None:
            cache_write_values.append(float(input_cache["write"]))
    for override in source.get("overrides") or []:
        cache = override.get("cache") or {}
        if cache.get("read") is not None:
            cache_read_values.append(float(cache["read"]))
        if cache.get("write") is not None:
            cache_write_values.append(float(cache["write"]))
    cache_read = max(cache_read_values) if cache_read_values else None
    cache_write = max(cache_write_values) if cache_write_values else None

    # Go's DeepSeek prices double during peak hours. The reservation must use
    # the peak price so a budget is never under-estimated; the response's
    # allowance corrects the settled amount.
    if provider == "go" and model["id"] in GO_PEAK_MODELS:
        input_price *= 2
        output_price *= 2
        if cache_read is not None:
            cache_read *= 2
        if cache_write is not None:
            cache_write *= 2
    return input_price, output_price, cache_read, cache_write


def number(value: float | None) -> str:
    if value is None:
        return "nil"
    text = f"{value:.10f}".rstrip("0").rstrip(".")
    return text if "." in text else text + ".0"


def allowance_literal(model_id: str, provider: str) -> str:
    if provider != "go":
        return "nil"
    values = GO_ALLOWANCES.get(model_id)
    if values is None:
        raise SystemExit(f"Missing Go monthly allowance for {model_id}")
    go, plus, teams = values
    if go is None and plus is None and teams is None:
        return "nil"
    return f"OpenCodePlanAllowance(go: {number(go)}, goPlus: {number(plus)}, goTeams: {number(teams)})"


def entry(model: dict, provider: str) -> str:
    input_price, output_price, cache_read, cache_write = prices(model, provider)
    is_free = input_price == 0 and output_price == 0
    return f"""        OpenCodePriceEntry(
            model: "{model['id']}",
            inputUSDPerMTok: {number(input_price)},
            outputUSDPerMTok: {number(output_price)},
            cacheReadUSDPerMTok: {number(cache_read)},
            cacheWriteUSDPerMTok: {number(cache_write)},
            allowance: {allowance_literal(model['id'], provider)},
            isFree: {str(is_free).lower()}
        ),"""


def entries(models: list[dict], provider: str) -> str:
    chat = sorted((model for model in models if model.get("type", "chat") == "chat"), key=lambda model: model["id"])
    return "\n".join(entry(model, provider) for model in chat)


def main() -> None:
    zen = fetch(ZEN_URL)["data"]
    go = fetch(GO_URL)["data"]
    output = f'''// Generated by scripts/generate-opencode-prices.py — do not edit by hand.
// Sources: {ZEN_URL} and {GO_URL}; monthly allowances from
// https://opencode.ai/docs/console/go. Updated {UPDATED_AT}.
//
// Prices are USD per 1M tokens. Go's DeepSeek entries use peak prices so a
// local reservation is a ceiling; the provider's `opencode.allowance` is the
// settled amount and always wins. Free models are kept for completeness but
// Zen's free tier is filtered out of the picker because non-OpenCode clients
// receive HTTP 403.

import Foundation

struct OpenCodePlanAllowance: Sendable, Equatable {{
    var go: Double?
    var goPlus: Double?
    var goTeams: Double?
}}

struct OpenCodePriceEntry: Sendable, Equatable {{
    var model: String
    var inputUSDPerMTok: Double
    var outputUSDPerMTok: Double
    var cacheReadUSDPerMTok: Double?
    var cacheWriteUSDPerMTok: Double?
    var allowance: OpenCodePlanAllowance?
    var isFree: Bool
}}

enum OpenCodePriceCatalog {{
    static let updatedAt = "{UPDATED_AT}"

    static let go: [OpenCodePriceEntry] = [
{entries(go, "go")}
    ]

    static let zen: [OpenCodePriceEntry] = [
{entries(zen, "zen")}
    ]

    /// Longest model id wins, matching the base catalog's prefix policy. A
    /// `:` suffix (a pinned snapshot) still resolves to its model.
    static func entry(for providerID: String, model: String) -> OpenCodePriceEntry? {{
        let entries: [OpenCodePriceEntry]
        switch providerID {{
        case AIProvider.opencodeGo.rawValue: entries = go
        case AIProvider.opencodeZen.rawValue: entries = zen
        default: return nil
        }}
        let key = model.lowercased()
        return entries
            .filter {{ key == $0.model.lowercased() || key.hasPrefix($0.model.lowercased() + ":") }}
            .max {{ $0.model.count < $1.model.count }}
    }}

    static func price(for providerID: String, model: String) -> ModelPrice? {{
        guard let entry = entry(for: providerID, model: model) else {{ return nil }}
        let rate = AIPriceCatalog.usdToCny
        return ModelPrice(
            provider: providerID,
            modelPrefix: entry.model,
            inputPerMTok: entry.inputUSDPerMTok * rate,
            outputPerMTok: entry.outputUSDPerMTok * rate,
            cacheReadPerMTok: entry.cacheReadUSDPerMTok.map {{ $0 * rate }},
            cacheWritePerMTok: entry.cacheWriteUSDPerMTok.map {{ $0 * rate }},
            currency: "CNY",
            updatedAt: updatedAt
        )
    }}

    static func hasPrices(for providerID: String) -> Bool {{
        switch providerID {{
        case AIProvider.opencodeGo.rawValue: return !go.isEmpty
        case AIProvider.opencodeZen.rawValue: return !zen.isEmpty
        default: return false
        }}
    }}
}}
'''
    OUTPUT.write_text(output, encoding="utf-8")
    print(f"Wrote {OUTPUT} ({len(go)} Go, {len(zen)} Zen)")


if __name__ == "__main__":
    main()
