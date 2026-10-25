"""夜の整理: `omi-server nightly`

1. 自宅サーバの処理 (話者の聞き分け・文字起こし) が終わるのを待つ
2. その日の timeline/ を作り直す
3. AI に、指示 (<data>/prompts/nightly.md) を渡して notes/ にまとめを書かせる
   - 既定は Codex (コマンド)。`--agent chatgpt` なら、Web 画面で接続した ChatGPT プランで自宅サーバから直接頼む
4. 結果を <data>/runs/nightly.jsonl に記録する (Web の「蓄積」・iPhone の「まとめ」に出る)

まとめは iPhone が次にサーバとやりとりしたとき (アプリを開いたとき・充電中の処理) に届く。
"""

from __future__ import annotations

import fcntl
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import date, datetime, timedelta, tzinfo
from pathlib import Path
from typing import Any, Callable

from .config import Settings

PROMPT_TEMPLATE = Path(__file__).parent / "static" / "nightly-prompt.md"
# プロンプトは標準入力で渡す。workspace-write なので書けるのはデータのディレクトリの中だけ (ネットワークも不可)。
DEFAULT_AGENT = "codex exec --skip-git-repo-check --sandbox workspace-write --cd {data_dir} -"
WEEKDAYS = "月火水木金土日"
# この時刻より前に動かしたときは、前の日を整理する (日付をまたいでから実行しても良いように)
DAY_ROLLOVER_HOUR = 5


# 自宅サーバから直接 ChatGPT (Sign in with ChatGPT) に頼むときの --agent
CHATGPT_AGENT = "chatgpt"
NOTE_MARK, TODO_MARK, END_MARK = "<<<NOTE>>>", "<<<TODO>>>", "<<<END>>>"
# 添付する会話の上限 (文字)。超えたら後ろを省く
MAX_TIMELINE_CHARS = 400_000

CHATGPT_SUFFIX = """

## この実行での読み書き

この実行では、自宅サーバが AI を直接呼んでいます。ファイルを開いたり書いたりはできません。

- 「読むもの」は、入力に `<file path="...">` ごとに添付してあります。無いものは添付していません。
- `AGENTS.md` (添付) の取り扱いの注意に従ってください。
- 書くものは、次の形式だけで出力してください。前後に説明を付けないでください。サーバがそれぞれのファイルに保存します。

{note_mark}
({note} の全文)
{todo_mark}
(notes/todo.md の全文。変更がなくても全文)
{end_mark}
"""


def chatgpt_materials(data_dir: Path, day: date, previous: Path | None) -> str:
    """AI に添付するファイル"""
    files = [("AGENTS.md", data_dir / "AGENTS.md"), ("vocabulary.md", data_dir / "vocabulary.md"),
             (f"timeline/{day.isoformat()}.md", data_dir / "timeline" / f"{day.isoformat()}.md")]
    if previous is not None:
        files.append((f"notes/{previous.name}", previous))
    files.append(("notes/todo.md", data_dir / "notes" / "todo.md"))
    parts = []
    for name, path in files:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if len(text) > MAX_TIMELINE_CHARS:
            text = text[:MAX_TIMELINE_CHARS] + "\n\n(長いので、ここから後ろは省きました)\n"
        parts.append(f'<file path="{name}">\n{text.rstrip()}\n</file>')
    return "\n\n".join(parts)


def parse_chatgpt_output(text: str) -> tuple[str | None, str | None]:
    """AI の出力から (その日のまとめ, todo.md) を取り出す"""
    if NOTE_MARK not in text:
        return None, None
    body = text.split(NOTE_MARK, 1)[1]
    note, _, rest = body.partition(TODO_MARK)
    todo = rest.split(END_MARK, 1)[0] if rest else None
    note = note.split(END_MARK, 1)[0].strip()

    def clean(s: str | None) -> str | None:
        if s is None:
            return None
        s = s.strip()
        # コードブロックで囲まれて返ってきたときは外す
        if s.startswith("```") and s.endswith("```"):
            s = s.split("\n", 1)[1].rsplit("```", 1)[0].strip() if "\n" in s else ""
        return s + "\n" if s else None

    return clean(note), clean(todo)


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def runs_path(data_dir: Path) -> Path:
    return data_dir / "runs" / "nightly.jsonl"


def last_run(data_dir: Path) -> dict[str, Any] | None:
    path = runs_path(data_dir)
    try:
        lines = path.read_text(encoding="utf-8").strip().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            return json.loads(line)
        except ValueError:
            continue
    return None


def append_run(data_dir: Path, record: dict[str, Any]) -> None:
    path = runs_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def prompt_path(data_dir: Path) -> Path:
    """利用者が書き換えられる指示ファイル。無ければ既定の文面で作る (以後は上書きしない)。"""
    path = data_dir / "prompts" / "nightly.md"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(PROMPT_TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
    return path


def render_prompt(template: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        template = template.replace("{{" + key + "}}", value)
    return template


def target_day(tz: tzinfo, now: datetime | None = None) -> date:
    now = (now or datetime.now(tz)).astimezone(tz)
    return now.date() - timedelta(days=1) if now.hour < DAY_ROLLOVER_HOUR else now.date()


def _now(tz: tzinfo) -> str:
    return datetime.now(tz).isoformat(timespec="seconds")


def _say(message: str) -> None:
    print(f"[nightly] {message}", flush=True)


def wait_for_queue(db: Any, minutes: float, poll_seconds: float = 15.0) -> int:
    """処理待ちが 0 になるまで待つ。戻り値は待ち終えた時点の処理待ちの数。"""
    deadline = time.monotonic() + minutes * 60
    while True:
        queues = db.queue_counts()
        pending = sum(q.get("queued", 0) + q.get("running", 0) for q in queues.values())
        if pending == 0 or time.monotonic() >= deadline:
            return pending
        _say(f"自宅サーバの処理待ち {pending} 件。終わるのを待っています…")
        time.sleep(poll_seconds)


def run(settings: Settings, *, day: date | None = None, wait_minutes: float = 60, agent: str | None = None,
        timeout_minutes: float = 40, dry_run: bool = False, model: str | None = None, chatgpt: Any = None,
        progress: Callable[[str, dict[str, Any]], None] | None = None) -> int:
    """戻り値: 0 = うまくいった (または飛ばした) / 1 = 失敗 / 2 = ほかの整理が実行中

    progress: 進み具合を知らせる (Web 画面から動かしたとき)。("waiting" | "writing" | "saving", 情報)
    """
    def report(phase: str, **info: Any) -> None:
        if progress:
            progress(phase, info)

    from .db import Database
    from .exporter import Exporter, local_tz

    settings.ensure_dirs()
    data_dir = settings.data_dir
    tz = local_tz(settings)
    day = day or target_day(tz)
    lock_path = data_dir / "runs" / "nightly.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = lock_path.open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        _say("別の整理が実行中です")
        return 2

    record: dict[str, Any] = {"started_at": _now(tz), "day": day.isoformat()}
    db = Database(data_dir / "omi.sqlite3")
    try:
        _say(f"{day.isoformat()} を整理します (データ: {data_dir})")
        report("waiting")
        pending = wait_for_queue(db, wait_minutes) if wait_minutes > 0 else 0
        record["pending"] = pending
        if pending:
            _say(f"処理待ちが {pending} 件残っています。終わっている分だけで整理します")

        exporter = Exporter(db, settings)
        exporter.write_agents_guide()
        exporter.export_day(day)
        timeline = data_dir / "timeline" / f"{day.isoformat()}.md"
        note = data_dir / "notes" / f"{day.isoformat()}.md"
        (data_dir / "notes").mkdir(exist_ok=True)
        if not timeline.exists():
            _say("この日の記録がありません")
            record.update(status="skipped", message="この日の記録がありません")
            return 0

        previous = sorted(p for p in (data_dir / "notes").glob("????-??-??.md") if p.stem < day.isoformat())
        prompt_file = prompt_path(data_dir)
        prompt = render_prompt(prompt_file.read_text(encoding="utf-8"), prompt_values(day, previous))

        command = agent if agent is not None else os.environ.get("OMI_AGENT_COMMAND") or DEFAULT_AGENT
        if command.strip().lower() == CHATGPT_AGENT:
            return _run_chatgpt(settings, db, record, day=day, prompt=prompt, note=note,
                                previous=previous[-1] if previous else None, model=model, chatgpt=chatgpt,
                                dry_run=dry_run, timeout_minutes=timeout_minutes, report=report)
        if command.strip().lower() in ("", "none"):
            rendered = data_dir / "runs" / f"prompt-{day.isoformat()}.md"
            rendered.write_text(prompt, encoding="utf-8")
            _say(f"AI は動かしません。指示を {rendered} に書き出しました")
            record.update(status="prepared", message="AI を動かさずに準備だけ")
            return 0

        values = {"data_dir": str(data_dir), "day": day.isoformat(), "note": str(note),
                  "prompt_file": str(data_dir / "runs" / f"prompt-{day.isoformat()}.md")}
        uses_file = "{prompt_file}" in command
        args = shlex.split(command)
        for key, value in values.items():
            args = [arg.replace("{" + key + "}", value) for arg in args]
        record["agent"] = Path(args[0]).name
        if uses_file:
            Path(values["prompt_file"]).write_text(prompt, encoding="utf-8")
        if dry_run:
            _say("実行するコマンド: " + shlex.join(args))
            record.update(status="dry-run")
            return 0

        before = note.stat().st_mtime if note.exists() else None
        _say(f"AI に整理を頼みます: {shlex.join(args[:2])} …")
        try:
            sys.stdout.flush()
            # 出力はそのまま端末 (自動実行なら nightly.log) に流す
            result = subprocess.run(args, input=None if uses_file else prompt, text=True, cwd=data_dir,
                                    timeout=timeout_minutes * 60)
            record["exit_code"] = result.returncode
        except FileNotFoundError:
            record.update(status="failed", message=f"{args[0]} が見つかりません")
            _say(record["message"])
            return 1
        except subprocess.TimeoutExpired:
            record.update(status="failed", message=f"{timeout_minutes:g} 分で終わりませんでした")
            _say(record["message"])
            return 1

        updated = note.exists() and note.stat().st_mtime != before
        record["note"] = f"notes/{day.isoformat()}.md" if note.exists() else None
        if result.returncode != 0:
            record.update(status="failed", message=f"AI が終了コード {result.returncode} で終わりました")
        elif not updated:
            record.update(status="failed", message=f"{record['note'] or 'notes/' + day.isoformat() + '.md'} が書かれませんでした")
        else:
            record.update(status="ok", message="まとめを書きました。iPhone は次にサーバとやりとりしたときに受け取ります")
        _say(record["message"])
        return 0 if record["status"] == "ok" else 1
    finally:
        record["finished_at"] = _now(tz)
        record.setdefault("status", "failed")
        record.setdefault("message", "途中で止まりました")
        if record["status"] != "dry-run":
            append_run(data_dir, record)
        db.close()
        lock.close()


def chatgpt_request(settings: Settings, day: date) -> dict[str, Any] | None:
    """ChatGPT に渡す指示と添付 (iPhone が自分で ChatGPT に頼むときに使う)。この日の記録がなければ None"""
    from .db import Database
    from .exporter import Exporter

    settings.ensure_dirs()
    data_dir = settings.data_dir
    db = Database(data_dir / "omi.sqlite3")
    exporter = Exporter(db, settings)
    exporter.write_agents_guide()
    exporter.export_day(day)
    if not (data_dir / "timeline" / f"{day.isoformat()}.md").exists():
        return None
    (data_dir / "notes").mkdir(exist_ok=True)
    previous = sorted(p for p in (data_dir / "notes").glob("????-??-??.md") if p.stem < day.isoformat())
    prompt = render_prompt(prompt_path(data_dir).read_text(encoding="utf-8"), prompt_values(day, previous))
    instructions = prompt + CHATGPT_SUFFIX.format(note=f"notes/{day.isoformat()}.md", note_mark=NOTE_MARK,
                                                  todo_mark=TODO_MARK, end_mark=END_MARK)
    materials = chatgpt_materials(data_dir, day, previous[-1] if previous else None)
    return {"day": day.isoformat(), "instructions": instructions, "materials": materials,
            "note": f"{day.isoformat()}.md",
            "pending": sum(q.get("queued", 0) + q.get("running", 0) for q in db.queue_counts().values())}


def prompt_values(day: date, previous: list[Path]) -> dict[str, str]:
    return {
        "day": day.isoformat(),
        "day_title": f"{day.month}月{day.day}日 ({WEEKDAYS[day.weekday()]})",
        "timeline_md": f"timeline/{day.isoformat()}.md",
        "timeline_jsonl": f"timeline/{day.isoformat()}.jsonl",
        "note": f"notes/{day.isoformat()}.md",
        "previous_note": f"notes/{previous[-1].name}" if previous else "(なし)",
    }


def _run_chatgpt(settings: Settings, db: Any, record: dict[str, Any], *, day: date, prompt: str, note: Path,
                 previous: Path | None, model: str | None, chatgpt: Any, dry_run: bool, timeout_minutes: float,
                 report: Callable[..., None]) -> int:
    """自宅サーバから ChatGPT (利用者のプラン) に直接頼み、返ってきたまとめを保存する"""
    from .chatgpt import ChatGPT, ChatGPTError

    data_dir = settings.data_dir
    gpt = chatgpt or ChatGPT(data_dir, open_listener=False)
    try:
        use_model = model or db.get_kv("chatgpt_model") or os.environ.get("OMI_CHATGPT_MODEL")
        if not use_model:
            models = gpt.list_models()
            if not models:
                raise ChatGPTError("この ChatGPT アカウントで使えるモデルがありません")
            use_model = models[0]["slug"]
        record["agent"] = f"chatgpt:{use_model}"
        instructions = prompt + CHATGPT_SUFFIX.format(note=f"notes/{day.isoformat()}.md", note_mark=NOTE_MARK,
                                                      todo_mark=TODO_MARK, end_mark=END_MARK)
        materials = chatgpt_materials(data_dir, day, previous)
        if dry_run:
            _say(f"ChatGPT ({use_model}) に、{len(materials):,} 文字を添付して頼みます")
            record.update(status="dry-run")
            return 0
        _say(f"ChatGPT ({use_model}) に整理を頼みます。添付 {len(materials):,} 文字")
        written = 0
        last = 0.0

        def on_delta(delta: str) -> None:
            nonlocal written, last
            written += len(delta)
            if time.monotonic() - last > 0.5:
                last = time.monotonic()
                report("writing", chars=written, model=use_model)

        report("writing", chars=0, model=use_model)
        output = gpt.respond(model=use_model, instructions=instructions, text=materials, on_delta=on_delta,
                             timeout=timeout_minutes * 60)
        report("saving", chars=len(output), model=use_model)
        note_text, todo_text = parse_chatgpt_output(output)
        if not note_text:
            (data_dir / "runs" / f"chatgpt-output-{day.isoformat()}.md").write_text(output, encoding="utf-8")
            record.update(status="failed", message="AI の出力から、まとめを読み取れませんでした (出力は runs/ に保存しました)")
            _say(record["message"])
            return 1
        write_atomic(note, note_text)
        if todo_text:
            write_atomic(data_dir / "notes" / "todo.md", todo_text)
        record.update(status="ok", note=f"notes/{day.isoformat()}.md",
                      message="まとめを書きました。iPhone は次にサーバとやりとりしたときに受け取ります")
        _say(record["message"])
        return 0
    except ChatGPTError as e:
        record.update(status="failed", message=e.message, code=e.code)
        _say(record["message"])
        return 1
