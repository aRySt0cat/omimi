#!/bin/zsh
# 夜の整理: その日の会話を AI (既定は Codex) にまとめさせ、data/notes/ に書かせる。
#
#   ./nightly-mac.sh                    今日 (午前 5 時前なら前の日) を整理
#   ./nightly-mac.sh --day 2026-10-10   日付を指定
#   ./nightly-mac.sh --agent none       AI は動かさず、指示 (data/runs/prompt-<日付>.md) だけ作る
#   ./nightly-mac.sh schedule 23:30     毎晩この時刻に自動で動かす (Mac にログインしている間)
#   ./nightly-mac.sh unschedule         自動実行をやめる
set -eu
cd "${0:A:h}"

export OMI_DATA_DIR="${OMI_DATA_DIR:-$PWD/data}"
# launchd から動かすと PATH が最小限なので、codex や uv のある場所を足す
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# AI のコマンド。{data_dir} はデータのディレクトリに置き換わり、指示は標準入力で渡す。
# workspace-write: 書き換えられるのはデータのディレクトリの中だけ、コマンドからのネットワーク接続は不可。
# (この ChatGPT アカウントでは既定のモデルが使えないため -m で指定している)
DEFAULT_AGENT='codex exec -m gpt-6-sol --skip-git-repo-check --sandbox workspace-write --cd {data_dir} -'
export OMI_AGENT_COMMAND="${OMI_AGENT_COMMAND:-$DEFAULT_AGENT}"

LABEL="local.omimi.nightly"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-}" in
  schedule)
    TIME="${2:-23:30}"
    HOUR="${TIME%%:*}"; MINUTE="${TIME##*:}"
    mkdir -p "$OMI_DATA_DIR/runs" "${PLIST:h}"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>${0:A}</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$((10#$HOUR))</integer><key>Minute</key><integer>$((10#$MINUTE))</integer></dict>
  <key>EnvironmentVariables</key>
  <dict><key>OMI_AGENT_COMMAND</key><string>${OMI_AGENT_COMMAND//&/&amp;}</string></dict>
  <key>StandardOutPath</key><string>$OMI_DATA_DIR/runs/nightly.log</string>
  <key>StandardErrorPath</key><string>$OMI_DATA_DIR/runs/nightly.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "毎晩 $TIME に整理します (AI: ${OMI_AGENT_COMMAND%% *}、記録: $OMI_DATA_DIR/runs/nightly.log)"
    exit 0
    ;;
  unschedule)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "自動実行をやめました"
    exit 0
    ;;
esac

echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"
if [[ -x .venv/bin/omi-server ]]; then
  exec .venv/bin/omi-server nightly "$@"
fi
exec uv run omi-server nightly "$@"
