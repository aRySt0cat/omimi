"""Web 画面から動かす「AI で整理する」。夜の整理 (nightly) を ChatGPT で、サーバの中で 1 件ずつ動かす。"""

from __future__ import annotations

import logging
import threading
from datetime import date, datetime, timezone
from typing import Any

from . import nightly
from .chatgpt import ChatGPT
from .config import Settings

log = logging.getLogger(__name__)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class AiRunner:
    def __init__(self, settings: Settings, chatgpt: ChatGPT):
        self.settings = settings
        self.chatgpt = chatgpt
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._state: dict[str, Any] = {"state": "idle"}

    def status(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self, day: date, model: str | None) -> dict[str, Any]:
        with self._lock:
            if self.running:
                raise RuntimeError("いま整理しています。終わってからもう一度試してください")
            self._state = {"state": "running", "day": day.isoformat(), "phase": "starting", "chars": 0,
                           "model": model, "started_at": _now()}
            self._thread = threading.Thread(target=self._run, args=(day, model), name="omi-ai", daemon=True)
            self._thread.start()
            return dict(self._state)

    def _progress(self, phase: str, info: dict[str, Any]) -> None:
        with self._lock:
            self._state.update(phase=phase, **info)

    def _run(self, day: date, model: str | None) -> None:
        try:
            code = nightly.run(self.settings, day=day, agent=nightly.CHATGPT_AGENT, wait_minutes=0, model=model,
                               chatgpt=self.chatgpt, progress=self._progress)
            last = nightly.last_run(self.settings.data_dir) or {}
            if code == 2:
                result = {"state": "failed", "message": "Mac で別の整理 (nightly) が実行中です。終わってから試してください"}
            elif last.get("status") == "skipped":
                result = {"state": "done", "message": last.get("message"), "skipped": True}
            elif code == 0:
                result = {"state": "done", "message": last.get("message"), "note": last.get("note")}
            else:
                result = {"state": "failed", "message": last.get("message") or "整理できませんでした",
                          "code": last.get("code")}
        except Exception as e:  # noqa: BLE001 - 画面に出す
            log.exception("AI run failed")
            result = {"state": "failed", "message": f"整理できませんでした ({type(e).__name__}: {e})"}
        with self._lock:
            self._state.update(result, finished_at=_now())
