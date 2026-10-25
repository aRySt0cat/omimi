"""コマンドライン: `omi-server serve | token | process | models | export | nightly | fingerprint`"""

from __future__ import annotations

import argparse
import base64
import hashlib
import logging
import re
import sys
from pathlib import Path

from .config import Settings


def cert_fingerprint(pem_path: Path) -> str:
    """PEM 証明書の SHA-256 フィンガープリント (アプリの証明書ピン留め欄に貼る値)。"""
    pem = pem_path.read_text()
    m = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if not m:
        raise ValueError(f"no certificate in {pem_path}")
    der = base64.b64decode("".join(m.group(1).split()))
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="omi-server")
    sub = parser.add_subparsers(dest="cmd", required=True)

    serve = sub.add_parser("serve", help="API サーバを起動")
    serve.add_argument("--host", default="0.0.0.0")
    serve.add_argument("--port", type=int, default=8000)
    serve.add_argument("--cert", type=Path, help="TLS 証明書 (PEM)")
    serve.add_argument("--key", type=Path, help="TLS 秘密鍵 (PEM)")

    sub.add_parser("token", help="API トークンを表示 (未設定なら生成)")

    tr = sub.add_parser("process", aliases=["transcribe"], help="キューに積まれた処理をこのプロセスで実行")
    tr.add_argument("--all-missing", action="store_true", help="サーバ文字起こしが無い全セグメントをキューに積む")
    tr.add_argument("--diarize-missing", action="store_true", help="話者分離していない全セグメントをキューに積む")

    sub.add_parser("models", help="話者分離のモデルを取得・検証する (オフライン運用の前準備)")

    ex = sub.add_parser("export", help="エージェント向けの timeline/ と AGENTS.md を作り直す")
    ex.add_argument("--day", help="YYYY-MM-DD (省略時は全日)")

    ni = sub.add_parser("nightly", help="夜の整理: 処理を待って、AI にその日のまとめを書かせる")
    ni.add_argument("--day", help="YYYY-MM-DD (省略時は今日。午前 5 時前なら前の日)")
    ni.add_argument("--agent", help="AI のコマンド ({data_dir} {day} {note} {prompt_file} を置き換え)。"
                                    "none なら指示を作るだけ。省略時は OMI_AGENT_COMMAND か codex exec")
    ni.add_argument("--wait-minutes", type=float, default=60, help="自宅サーバの処理を待つ上限 (分)")
    ni.add_argument("--timeout-minutes", type=float, default=40, help="AI の実行時間の上限 (分)")
    ni.add_argument("--dry-run", action="store_true", help="実行するコマンドを表示するだけ")

    fp = sub.add_parser("fingerprint", help="証明書の SHA-256 フィンガープリントを表示")
    fp.add_argument("cert", type=Path)

    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = Settings.from_env()

    if args.cmd == "serve":
        import uvicorn

        from .app import create_app

        settings.ensure_dirs()
        print(f"data dir: {settings.data_dir}", file=sys.stderr)
        if not settings.api_tokens:
            print(f"token file: {settings.data_dir / 'token'}  (`omi-server token` で表示)", file=sys.stderr)
        if args.cert:
            print(f"certificate SHA-256: {cert_fingerprint(args.cert)}", file=sys.stderr)
        uvicorn.run(create_app(settings), host=args.host, port=args.port,
                    ssl_certfile=str(args.cert) if args.cert else None,
                    ssl_keyfile=str(args.key) if args.key else None,
                    proxy_headers=False, server_header=False,
                    # iPhone のバックグラウンド送信は接続を開いたままにするので、止めるときに待ちすぎない。
                    # 途中だった処理は、次に起動したときにやり直す
                    timeout_graceful_shutdown=10)
        return 0

    if args.cmd == "token":
        print(settings.resolve_tokens()[0])
        return 0

    if args.cmd in ("process", "transcribe"):
        from .db import Database
        from .worker import TranscriptionWorker

        settings.ensure_dirs()
        db = Database(settings.data_dir / "omi.sqlite3")
        if args.all_missing:
            with db.tx() as c:
                n = c.execute("""UPDATE segments SET server_stt_status='queued'
                                 WHERE server_stt_status IN ('none', 'failed')""").rowcount
            print(f"queued {n} segments for transcription")
        if args.diarize_missing:
            with db.tx() as c:
                n = c.execute("""UPDATE segments SET diarization_status='queued'
                                 WHERE diarization_status IN ('none', 'failed')""").rowcount
            print(f"queued {n} segments for diarization")
        db.requeue_running()
        worker = TranscriptionWorker(db, settings)
        print(f"processed {worker.drain()} segments")
        return 0

    if args.cmd == "models":
        from . import models

        ok = True
        for spec in models.ALL:
            path = models.ensure(spec, settings.models_path, settings.allow_model_download)
            valid = models.verify(spec, path)
            ok &= valid
            print(f"{spec.name}: {path} ({'sha256 ok' if valid else 'sha256 MISMATCH'})")
        return 0 if ok else 1

    if args.cmd == "export":
        from datetime import date

        from .db import Database
        from .exporter import Exporter

        settings.ensure_dirs()
        exporter = Exporter(Database(settings.data_dir / "omi.sqlite3"), settings)
        exporter.write_agents_guide()
        days = [date.fromisoformat(args.day)] if args.day else sorted(exporter.all_days())
        for day in days:
            exporter.export_day(day)
        print(f"exported {len(days)} days to {settings.data_dir / 'timeline'}")
        return 0

    if args.cmd == "nightly":
        from datetime import date

        from . import nightly

        return nightly.run(settings, day=date.fromisoformat(args.day) if args.day else None, agent=args.agent,
                           wait_minutes=args.wait_minutes, timeout_minutes=args.timeout_minutes, dry_run=args.dry_run)

    if args.cmd == "fingerprint":
        print(cert_fingerprint(args.cert))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
