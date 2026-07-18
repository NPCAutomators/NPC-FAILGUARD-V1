"""NPC FailGuard - daemon entry point (uvicorn runner)."""

import sys

import uvicorn

import config


def main() -> None:
    try:
        uvicorn.run(
            "proxy:app",
            host=config.HOST,
            port=config.PORT,
            log_level="warning",   # app logs go to core/logs/proxy.log
        )
    except Exception as exc:  # startup errors must land in the journal
        print(f"npc-failguard failed to start: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
