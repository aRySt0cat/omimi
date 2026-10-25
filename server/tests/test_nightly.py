import json
import shlex
import sys
from datetime import date, datetime
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient
from test_api import TOKEN, FakeDiarizer, FakeEngine, make_ogg, put_audio

from omi_home_server import nightly, stats
from omi_home_server.app import create_app
from omi_home_server.config import Settings
from omi_home_server.notes import NotesStore, summarize, valid_name

DAY_NOTE = """# 10月10日 (土)

> 午前は **設計** の相談、午後は [買い物](https://example.com)。

## 話したこと

- **12:00 設計** — 自分と話者2。[12:00](omimi://segment/s1)
"""


def make_env(tmp_path, **kw):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none", timezone="Asia/Tokyo", **kw)
    app = create_app(settings, engine_factory=FakeEngine, diarizer_factory=FakeDiarizer, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    return client, app, settings


def write_notes(settings):
    notes = settings.data_dir / "notes"
    (notes / "people").mkdir(parents=True)
    (notes / "2026-10-10.md").write_text(DAY_NOTE)
    (notes / "2026-10-09.md").write_text("# 10月9日\n\n本文だけの日。\n")
    (notes / "todo.md").write_text("# やること\n\n- [ ] 見積もりを送る\n")
    (notes / "people" / "田中.md").write_text("# 田中さん\n")
    (notes / ".hidden.md").write_text("# secret\n")
    (settings.data_dir / "token").write_text("secret-token\n")


def test_note_names_and_summary():
    assert valid_name("2026-10-10.md") and valid_name("people/田中.md") and valid_name("todo list.md")
    for bad in ("../token", "a/../../x.md", ".hidden.md", "x.txt", "a/b/c/d.md", "/abs.md", "a\\b.md", "a$.md", ""):
        assert not valid_name(bad), bad
    assert summarize(DAY_NOTE) == ("10月10日 (土)", "午前は 設計 の相談、午後は 買い物。")
    assert summarize("# 題\n\n- 箇条書き\n\n本文の段落。\n続き。\n\n## 次") == ("題", "本文の段落。 続き。")
    assert summarize("本文だけ")[0] is None


def test_notes_api(tmp_path):
    client, app, settings = make_env(tmp_path)
    assert client.get("/api/v1/notes").json() == {"notes": []}
    write_notes(settings)
    notes = client.get("/api/v1/notes").json()["notes"]
    assert [n["name"] for n in notes] == ["2026-10-10.md", "2026-10-09.md", "people/田中.md", "todo.md"]
    first = notes[0]
    assert first["kind"] == "day" and first["date"] == "2026-10-10" and first["title"] == "10月10日 (土)"
    assert first["summary"].startswith("午前は 設計") and len(first["sha256"]) == 64
    assert notes[3]["kind"] == "note" and notes[3]["date"] is None and notes[3]["title"] == "やること"

    body = client.get("/api/v1/notes/people/田中.md").json()
    assert body["text"] == "# 田中さん\n"
    assert client.get("/api/v1/notes/todo.md").json()["text"].startswith("# やること")
    for bad in ("..%2Ftoken", "../token", ".hidden.md", "nope.md", "people/../../token"):
        assert client.get(f"/api/v1/notes/{bad}").status_code in (404, 400), bad
    assert client.get("/api/v1/notes", headers={"Authorization": "Bearer no"}).status_code == 401


def test_stats_and_iphone_pull(tmp_path):
    client, app, settings = make_env(tmp_path)
    ogg = make_ogg(tmp_path / "a.opus")
    put_audio(client, "s1", ogg)  # 2026-10-10 12:00 JST、話者分離で 2 秒の発話
    put_audio(client, "s2", ogg, started_at="2026-10-09T03:00:00.000Z")
    client.put("/api/v1/markers/m1", json={"kind": "highlight", "at": "2026-10-10T03:00:00.500Z"})
    write_notes(settings)

    before = stats.compute(app.state.db, settings, days=3, today=date(2026, 10, 10))
    assert before["totals"]["pending_segments"] == 2 and before["queues"]["pending"] == 2
    assert before["pipeline"]["pending"] == 2 and before["pipeline"]["iphone_notes_pull_at"] is None
    app.state.worker.drain()

    s = stats.compute(app.state.db, settings, days=3, today=date(2026, 10, 10))
    t = s["totals"]
    assert t["segments"] == 2 and t["speech_segments"] == 2 and t["days"] == 2
    assert t["recorded_seconds"] == 4.0 and t["speech_seconds"] == 4.0
    assert t["markers"] == {"highlight": 1, "split": 0, "memo": 0} and t["speakers"] == 2
    assert s["storage"]["audio_bytes"] == 2 * len(ogg) and s["storage"]["db_bytes"] > 0
    assert s["storage"]["notes_bytes"] > 0 and s["storage"]["timeline_bytes"] > 0
    assert [d["date"] for d in s["days"]] == ["2026-10-10", "2026-10-09", "2026-10-08"]
    assert s["days"][0] == {"date": "2026-10-10", "segments": 1, "speech_segments": 1, "silent_segments": 0,
                            "pending_segments": 0, "recorded_seconds": 2.0, "speech_seconds": 2.0, "markers": 1,
                            "note": True}
    assert s["days"][2]["segments"] == 0 and not s["days"][2]["note"]
    assert s["notes"] == {"count": 4, "days": 2, "latest_updated_at": s["notes"]["latest_updated_at"]}
    assert s["pipeline"]["pending"] == 0 and s["pipeline"]["note"]["name"] == "2026-10-10.md" and s["pipeline"]["day"] == "2026-10-10"

    # Web 画面から一覧を見ても記録しない。iPhone (User-Agent) が取りに来たら記録する
    client.get("/api/v1/notes")
    assert client.get("/api/v1/stats").json()["pipeline"]["iphone_notes_pull_at"] is None
    client.get("/api/v1/notes", headers={"User-Agent": "omi-original-app/1"})
    assert client.get("/api/v1/stats").json()["pipeline"]["iphone_notes_pull_at"]


def test_guide_is_public(tmp_path):
    client, *_ = make_env(tmp_path)
    r = client.get("/guide.md", headers={"Authorization": ""})
    assert r.status_code == 200 and r.text.startswith("# 毎日の流れ")
    assert r.headers["content-type"].startswith("text/markdown")


def test_target_day_rolls_over_before_5am():
    tz = ZoneInfo("Asia/Tokyo")
    assert nightly.target_day(tz, datetime(2026, 10, 11, 1, 30, tzinfo=tz)) == date(2026, 10, 10)
    assert nightly.target_day(tz, datetime(2026, 10, 10, 23, 30, tzinfo=tz)) == date(2026, 10, 10)


def fake_agent(script: str) -> str:
    return shlex.join([sys.executable, "-c", script])


def test_nightly_runs_agent_and_records(tmp_path, capsys):
    client, app, settings = make_env(tmp_path)
    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"))
    app.state.worker.drain()
    # 指示 (標準入力) に日付と書き先が入っていることを確かめてから、まとめを書く
    agent = fake_agent(
        "import sys, pathlib; p = sys.stdin.read(); "
        "assert '10月10日 (土)' in p and 'notes/2026-10-10.md' in p and 'timeline/2026-10-10.md' in p, p; "
        "pathlib.Path('notes/2026-10-10.md').write_text('# まとめ\\n\\n> よい日\\n')")
    assert nightly.run(settings, day=date(2026, 10, 10), agent=agent, wait_minutes=0) == 0
    assert (settings.data_dir / "notes/2026-10-10.md").read_text().startswith("# まとめ")
    assert (settings.data_dir / "prompts/nightly.md").exists()
    run = nightly.last_run(settings.data_dir)
    assert run["status"] == "ok" and run["day"] == "2026-10-10" and run["note"] == "notes/2026-10-10.md"
    assert run["exit_code"] == 0 and run["agent"].startswith("python")
    assert client.get("/api/v1/stats").json()["pipeline"]["last_run"]["status"] == "ok"

    # 指示ファイルは書き換えたら次から反映され、上書きされない
    (settings.data_dir / "prompts/nightly.md").write_text("独自の指示 {{day}}")
    assert nightly.run(settings, day=date(2026, 10, 10), agent="none", wait_minutes=0) == 0
    assert (settings.data_dir / "runs/prompt-2026-10-10.md").read_text() == "独自の指示 2026-10-10"
    assert nightly.last_run(settings.data_dir)["status"] == "prepared"


def test_nightly_failures(tmp_path):
    client, app, settings = make_env(tmp_path)
    # 記録のない日は飛ばす
    assert nightly.run(settings, day=date(2026, 10, 1), agent=fake_agent("pass"), wait_minutes=0) == 0
    assert nightly.last_run(settings.data_dir)["status"] == "skipped"

    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"))
    app.state.worker.drain()
    # まとめを書かずに終わった / 異常終了 / コマンドが無い
    assert nightly.run(settings, day=date(2026, 10, 10), agent=fake_agent("import sys; sys.stdin.read()"),
                       wait_minutes=0) == 1
    assert "書かれませんでした" in nightly.last_run(settings.data_dir)["message"]
    assert nightly.run(settings, day=date(2026, 10, 10), agent=fake_agent("raise SystemExit(3)"), wait_minutes=0) == 1
    assert nightly.last_run(settings.data_dir)["exit_code"] == 3
    assert nightly.run(settings, day=date(2026, 10, 10), agent="no-such-agent-xyz", wait_minutes=0) == 1
    lines = (settings.data_dir / "runs/nightly.jsonl").read_text().splitlines()
    assert [json.loads(x)["status"] for x in lines] == ["skipped", "failed", "failed", "failed"]


def test_agent_placeholders_and_literal_braces(tmp_path):
    client, app, settings = make_env(tmp_path)
    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"))
    app.state.worker.drain()
    # {note} などは置き換え、それ以外の波かっこ (zsh の展開ミスなど) はそのまま渡す
    script = ("import sys, pathlib; assert sys.argv[2] == '{x', sys.argv; "
              "pathlib.Path(sys.argv[1]).write_text('# ok\\n')")
    agent = shlex.join([sys.executable, "-c", script]) + " {note} '{x'"
    assert nightly.run(settings, day=date(2026, 10, 10), agent=agent, wait_minutes=0) == 0
    assert (settings.data_dir / "notes/2026-10-10.md").read_text() == "# ok\n"
