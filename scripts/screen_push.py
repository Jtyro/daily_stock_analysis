# -*- coding: utf-8 -*-
"""
===================================
选股结果定时推送
===================================

运行内置选股引擎（默认「资金热度」策略），把选出的股票推送到已在 .env 配置的通知渠道。
适合配合系统计划任务使用，例如每个 A 股交易日的 14:30 运行一次，收盘前拿到候选。

本脚本只做三件事：复用 `ScreeningService` 选股、格式化 Markdown、调用 `NotificationService` 推送；
选股逻辑与评分完全复用内置引擎，不在这里重复实现。

使用方法：
    python scripts/screen_push.py                              # 资金热度 / A股 / 3 只
    python scripts/screen_push.py --dry-run                    # 只打印，不落库、不推送
    python scripts/screen_push.py --force                      # 跳过交易日检查
    python scripts/screen_push.py --strategy dual_low --max-results 5

退出码：
    0  正常结束（包含「非交易日跳过」）
    1  选股失败或推送失败
"""
import os
# 代理配置 - 由 USE_PROXY 控制，默认关闭；与 scripts/check_env.py 保持一致
if os.getenv("GITHUB_ACTIONS") != "true" and os.getenv("USE_PROXY", "false").lower() == "true":
    _proxy_host = os.getenv("PROXY_HOST", "127.0.0.1")
    _proxy_port = os.getenv("PROXY_PORT", "10809")
    _proxy_url = f"http://{_proxy_host}:{_proxy_port}"
    os.environ["http_proxy"] = _proxy_url
    os.environ["https_proxy"] = _proxy_url

import argparse
import logging
import sys
import time
from datetime import date, datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.check_env import _reconfigure_output_stream  # noqa: E402

DEFAULT_STRATEGY = "capital_heat"
DEFAULT_MARKET = "cn"
DEFAULT_MAX_RESULTS = 3


def resolve_strategy_label(strategy: str) -> str:
    """把策略 id 换成展示名（如 capital_heat -> 资金热度选股）。"""
    display = strategy
    try:
        from src.services.screening.strategy import list_strategies

        for info in list_strategies():
            if getattr(info, "name", "") == strategy:
                display = getattr(info, "display_name", "") or strategy
                break
    except Exception as exc:  # noqa: BLE001 - 展示名解析失败时回退到策略 id
        logger.warning("策略展示名解析失败，回退使用 id: %s", exc)
    return f"{display}选股" if not display.endswith("选股") else display


def configure_console_encoding() -> None:
    """避免在旧版 Windows 代码页下出现 UnicodeEncodeError。"""
    for stream in (sys.stdout, sys.stderr):
        _reconfigure_output_stream(stream)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("screen_push")


def _format_amount(value) -> str:
    """把成交额（元）格式化为易读的亿/万。"""
    try:
        amount = float(value)
    except (TypeError, ValueError):
        return "-"
    if amount >= 1e8:
        return f"{amount / 1e8:.2f}亿"
    if amount >= 1e4:
        return f"{amount / 1e4:.2f}万"
    return f"{amount:.0f}"


def _format_pct(value) -> str:
    try:
        pct = float(value)
    except (TypeError, ValueError):
        return "-"
    return f"{pct:+.2f}%"


def _explanation_text(value) -> str:
    """入选理由可能是字符串、结构化解释块或它们的列表，统一抽成可读文本。"""
    if not value:
        return ""
    if isinstance(value, str):
        return " ".join(value.split())
    if isinstance(value, dict):
        for key in ("text", "content"):
            text = _explanation_text(value.get(key))
            if text:
                return text
        return ""
    if isinstance(value, (list, tuple)):
        parts = []
        for entry in value:
            text = _explanation_text(entry)
            if text and text not in parts:
                parts.append(text)
        return "；".join(parts)
    return ""


def _pick_reason(item: dict) -> str:
    """优先使用可读性更好的入选理由，避免把结构化对象直接打印出来。"""
    for key in ("why_selected", "why_now", "ranking_reason", "reason"):
        text = _explanation_text(item.get(key))
        if text:
            return text[:200]
    return ""


def build_markdown(result: dict, *, strategy_label: str, max_results: int, now: datetime) -> str:
    """把选股结果渲染成适合通知渠道的紧凑 Markdown。"""
    candidates = result.get("candidates") or []
    lines = [
        f"## 📊 {strategy_label} · A股",
        f"**{now:%Y-%m-%d %H:%M}** ｜ 候选 "
        f"{result.get('after_filter_count') or result.get('candidate_count') or '-'} "
        f"→ 入选 **{len(candidates)}** 只",
    ]

    if not candidates:
        lines.append("")
        lines.append("本次没有符合条件的标的。")
    else:
        for item in candidates[:max_results]:
            rank = item.get("rank") or "-"
            name = item.get("name") or ""
            code = item.get("code") or ""
            score = item.get("score")
            score_text = f"{float(score):.1f}" if isinstance(score, (int, float)) else "-"
            lines.append("")
            lines.append(f"**{rank}. {name} ({code})**　评分 {score_text}")
            lines.append(
                f"现价 {item.get('price', '-')} ｜ 涨幅 {_format_pct(item.get('change_pct'))} "
                f"｜ 成交额 {_format_amount(item.get('amount'))}"
            )
            reason = _pick_reason(item)
            if reason:
                lines.append(f"入选理由：{reason}")

    # 告警面向通知渠道，需要收敛：快照源回退属于环境性诊断噪音（例如东财不可达），
    # 每天都可能出现，放进推送只会淹没真正重要的降级信息（如 LLM 排序失败）。
    warnings = []
    for raw in (result.get("warnings") or []):
        text = " ".join(str(raw).split())
        if not text or text.startswith("Snapshot source fallback"):
            continue
        if text not in warnings:
            warnings.append(text)
    if warnings:
        lines.append("")
        summary = "；".join(warnings[:2])
        if len(warnings) > 2:
            summary += f"（另有 {len(warnings) - 2} 条见报告）"
        lines.append(f"> ⚠️ {summary[:150]}{'…' if len(summary) > 150 else ''}")

    lines.append("")
    lines.append(
        f"> 策略 {result.get('strategy') or '-'} v{result.get('strategy_version') or '-'}"
        f" ｜ 快照源 {result.get('snapshot_source') or '-'}"
        f" ｜ 运行 {result.get('run_id') or '-'}"
    )
    lines.append("> 仅为程序化筛选结果，不构成投资建议。")
    return "\n".join(lines)


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="运行内置选股引擎并推送结果到已配置的通知渠道",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--strategy", default=DEFAULT_STRATEGY, help=f"策略 id（默认 {DEFAULT_STRATEGY}）")
    parser.add_argument("--market", default=DEFAULT_MARKET, help=f"市场（默认 {DEFAULT_MARKET}）")
    parser.add_argument(
        "--max-results", type=int, default=DEFAULT_MAX_RESULTS,
        help=f"返回数量（默认 {DEFAULT_MAX_RESULTS}）",
    )
    parser.add_argument("--title", default="", help="报告标题覆盖（默认按策略展示名生成，如「资金热度选股」）")
    parser.add_argument("--dry-run", action="store_true", help="只打印结果，不落库、不推送")
    parser.add_argument("--force", action="store_true", help="跳过交易日检查，强制执行")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    configure_console_encoding()
    args = parse_args(argv)
    now = datetime.now()

    # --- 交易日闸门：非交易日直接跳过，避免周末/节假日推送噪音 ---
    if not args.force:
        try:
            from src.core.trading_calendar import is_market_open

            if not is_market_open(args.market, date.today()):
                logger.info("%s 市场 %s 非交易日，跳过本次选股推送", date.today(), args.market)
                return 0
        except Exception as exc:  # noqa: BLE001 - 日历不可用时 fail-open，继续执行
            logger.warning("交易日检查失败，按交易日继续执行: %s", exc)

    try:
        from src.config import get_config
        from src.services.screening_service import ScreeningService
        from src.storage import DatabaseManager

        config = get_config()
        db_manager = DatabaseManager.get_instance()
        service = ScreeningService(config=config, db_manager=db_manager)
    except Exception as exc:  # noqa: BLE001 - 初始化失败需要可见的失败
        logger.error("初始化选股服务失败: %s", exc, exc_info=True)
        return 1

    logger.info(
        "开始选股: strategy=%s market=%s max_results=%s",
        args.strategy, args.market, args.max_results,
    )
    started = time.time()
    try:
        result = service.screen(
            strategy=args.strategy,
            market=args.market,
            max_results=args.max_results,
        )
    except Exception as exc:  # noqa: BLE001 - 选股失败必须非零退出，便于计划任务告警
        logger.error("选股执行失败: %s", exc, exc_info=True)
        return 1

    elapsed = time.time() - started
    candidates = result.get("candidates") or []
    logger.info("选股完成，耗时 %.1fs，入选 %d 只", elapsed, len(candidates))

    markdown = build_markdown(
        result,
        strategy_label=args.title.strip() or resolve_strategy_label(args.strategy),
        max_results=args.max_results,
        now=now,
    )

    if args.dry_run:
        print("\n" + "=" * 60)
        print(markdown)
        print("=" * 60)
        print("\n--dry-run：未落库、未推送")
        return 0

    # --- 保存并推送：任一环节失败都只记 warning，不影响另一环节 ---
    try:
        from src.notification import NotificationService

        notifier = NotificationService()
    except Exception as exc:  # noqa: BLE001 - 通知服务不可用不应让选股结果丢失
        logger.error("通知服务初始化失败，选股结果未推送:\n%s\n%s", exc, markdown)
        return 1

    filename = f"screen_{args.strategy}_{now:%Y%m%d_%H%M}.md"
    try:
        path = notifier.save_report_to_file(markdown, filename)
        logger.info("选股报告已保存: %s", path)
    except Exception as exc:  # noqa: BLE001 - 保存失败不阻断推送
        logger.warning("选股报告保存失败: %s", exc)

    if not notifier.is_available():
        logger.warning("未配置任何通知渠道，跳过推送")
        return 0

    try:
        if notifier.send(markdown, route_type="report"):
            logger.info("选股结果推送成功")
            return 0
        logger.error("选股结果推送失败")
        return 1
    except Exception as exc:  # noqa: BLE001 - 推送异常按失败处理
        logger.error("选股结果推送异常: %s", exc, exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
