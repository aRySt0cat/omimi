# Omimi

(リポジトリ名: omi-original-app)

Omi (24 時間録音のウェアラブル) 用の自作 iPhone アプリです。録音・文字起こし・話者の聞き分け・AI のまとめまで、iPhone だけで完結します。
音声や文字起こしを、意図しないまま外部のクラウドへ送らないことを目的にしています。

```
 Omi ──BLE──▶ iPhone アプリ (Omimi)
              ├ バックグラウンドで常時受信、5 分ごとに Ogg Opus で保存 (再エンコードなし)
              ├ Apple の端末内音声認識で文字起こし (日本語・英語を自動判別、用語集をヒントに)
              ├ 端末内の AI モデル (Core ML) で話者を聞き分け、名前を付けた人の声を学習
              ├「AI で整理」: 選んだ日・時間帯の会話を ChatGPT (利用者のプラン) でまとめる ──▶ OpenAI (使ったときだけ)
              └ 音声と文字起こしを書き出し (zip) ──▶ AirDrop・「ファイル」で PC へ
```

## できること

1. **バックグラウンド録音**: CoreBluetooth の状態復元と自動再接続を使います。アプリが裏に回っても、OS に終了されても受信を続けます。音声は Ogg Opus ファイルとして保存されます。保存の単位 (録音) は、話し終えて 30 秒無音が続いたとき、または最大 5 分 (変更可) で区切られます。Omi は無音が 10 秒続くとマイクを休止して送信を止めるため、時刻は受信時刻を基準にし、短い途切れは無音で埋めます。BLE パケットの欠落は Opus の PLC で埋めます。
2. **Apple の文字起こし**: iOS 26 の `SpeechAnalyzer` / `SpeechTranscriber` を使います。音声は端末の外に出ません。日本語と英語の認識器を同時に動かし、「信頼度が高く、文字列も英語と判定される」区間だけ英語を採用します。
3. **話者の聞き分け (iPhone)**: pyannote segmentation-3.0 と WeSpeaker ResNet34 を Core ML に変換してアプリに同梱し (`ios/Tools/convert_speaker_models.py`)、充電中とアプリを開いているときに話者を聞き分けます (Neural Engine)。手順は sherpa-onnx の pyannote の実装を Swift に移したものです (`OmiKit/Sources/OmiSpeakers`)。
   - **大事な人だけに名前を付ける**: 名前のない声 (店員・アナウンスなど) は「その他」として灰色で表示します。会話の中では人ごとに分けて見せます。
   - **声を学習する**: 会話の中の話者名をタップして名前を付けたり直したりすると、iPhone がその人の声を学習し (`VoiceTrainer`: 埋め込みの重心と、話者の違いを強調する変換。人が直した発話を重く扱います)、次からの録音と過去の録音の名前を付け直します。
   - **その人らしくない発話を確かめる**: 「設定 → 話者と声の学習」で人を選ぶと、声が似ていない発話が「確認したい」に並びます。再生して直せます。名前の変更・統合 (同じ名前にする)・外すこともできます。
4. **Omi のボタンで印を付ける**: 受け付けると Omi が振動します。

   | 操作 | 印 | 意味 |
   |---|---|---|
   | 1 回押し | ⭐ 注目 | ここは大事 |
   | 2 回押し | ✂️ 区切り | 話題の切れ目。録音もここで区切ります |
   | 押して 1〜2 秒で離す | 📝 メモ | この後に話すことは自分へのメモ・指示 |

   3 秒以上押し続けると Omi の電源が切れます (ファームウェアの仕様)。ボタン操作は接続中のみ記録されます。
5. **話し声のない録音の整理**: Omi は物音でもマイクが起きるため、話し声のない短い録音ができます。「話し声のない録音 N 件」として畳んで表示し、まとめて削除できます。
6. **記録の見方を切り替える**: 「記録」画面はピンチで細かさを変えられます。ピンチインで「時間ごと」(1 時間ずつの帯と話者)、ピンチアウトで「会話ごと」→「全文」になります。
7. **AI で整理 (Sign in with ChatGPT)**: 「まとめ」→「AI で整理」で、[Sign in with ChatGPT](https://developers.openai.com/siwc) により利用者の ChatGPT プランでまとめます。iPhone を 1 つのホストとして登録し (PKCE、戻りは iPhone の 127.0.0.1:1455 で受け取る)、トークンはキーチェーン (この端末だけ) に置いて、iPhone から Responses API を呼びます (`store: false`)。
   - **指示 (プロンプト) を付け替える**: 「1 日のまとめ」「会議の議事録」「やることの洗い出し」「ふり返り日記」が最初から入っています。書き換えて保存したり、複製して自分用の指示を作ったりできます (`AIPrompts` / `AIPromptStore`)。指示ごとに、書くもの (その日のまとめ / 別のノート)、やること (todo) を書き直すか、前の日のまとめを添付するか、いつもの時間帯を決められます。
   - **時間帯を指定する**: 整理するときに「時間帯を決める」で、その間の発話と印だけを添付します (会議の議事録など)。
   - **送る内容を見る**: 送る前に、指示と添付 (会話・用語集・前の日のまとめ・やること) をそのまま確かめられます。
   - まとめは「まとめ」タブと「記録」の日付の下に出ます。まとめの中の時刻をタップするとその会話が開きます。
8. **用語集**: 人名・専門用語の正しい表記・読み・よく間違う表記・説明を登録します (「設定 → 用語集」)。Apple の音声認識に contextualStrings として渡し、「よく間違う表記」は表示と書き出しで正しい表記に置き換えます。AI には `vocabulary.md` として添付します。
9. **検索**: 下の「検索」(虫めがね) で、会話の文字起こしと AI のまとめを言葉で探します (`TextSearch`)。ひらがな・カタカナ・全角・半角・大文字小文字の違いは同じとみなし、かなで入れると漢字の言葉も読みで探します (「みつもり」で「見積もり」、用語集の読み「しもがうち」で「下河内」)。空白で区切るとすべてを含むものを探します。右上の絞り込みで、言語 (日本語・英語)・日付 (今日・昨日・直近 7 日・直近 30 日・期間を選ぶ)・時間帯 (朝・日中・夜・深夜・時間を選ぶ。22:00〜2:00 のように日をまたぐ範囲も)・話者で絞れます。言葉を入れずに、条件だけで探すこともできます (「今日の英語の発話」など)。まとめは日付でだけ絞れます。結果をタップすると、その発話の位置で会話が開き、言葉が強調されます。
10. **書き出し (PC での分析用)**: 「設定 → 音声と文字起こしを書き出す」で、期間を選んで別々に書き出します。zip にして共有シート (AirDrop・「ファイル」など) で渡します (`OmiExport`)。
   - **音声**: `<日付>/<日付>_<時刻>_<録音 ID>.opus` (そのまま) または `.wav` (16 kHz / 16 bit)。録音の一覧 `recordings.csv` / `.jsonl`。
   - **文字起こし**: 発話ごとの `utterances.csv` (Excel 用に BOM 付き) / `utterances.jsonl` (時刻は ISO 8601、話者・言語・人が直したか・用語集で直す前の文)、録音ごとの字幕 `subtitles/<日付>/<音声と同じ名前>.srt`、日ごとの `days/<日付>.md`、印 `markers.csv`。

## プライバシー設計

| 項目 | 対応 |
|---|---|
| 外部 SDK | 依存ゼロです。Opus のデコードは AudioToolbox、話者の聞き分けは Core ML (モデルはアプリに同梱) で行います |
| 通信先 | Omi (BLE)、Apple の音声モデル配信 (初回のみ)、「AI で整理」を使ったときだけ OpenAI (auth.openai.com / api.openai.com) |
| AI に送るもの | 選んだ日 (時間帯) の文字起こし・用語集・前の日のまとめ・やることだけです。送る前に中身を確かめられます。Responses API は `store: false` で呼びます |
| 端末内の保存 | データ保護 (初回ロック解除後) を有効にし、iCloud バックアップからは除外します。ChatGPT のトークンは Keychain (`ThisDeviceOnly`) に保存します |
| 書き出し | 利用者が期間を選んで共有シートで渡したときだけ、端末の外に出ます |

## 構成

```
ios/
  project.yml              XcodeGen 定義 (iOS 26+)
  OmiKit/                  コアライブラリ (Swift Package, macOS でテスト可)
    Sources/OmiKit/        BLE プロトコル, パケット組立, Opus, Ogg, 録音, 話者の照合と学習, AI で整理, 書き出し
    Sources/OmiSpeakers/   Core ML による話者分離 (fbank・区切り・声の特徴・まとめ方)
    Sources/OmiTranscription/  Apple SpeechAnalyzer による文字起こし
    Sources/omikit-cli/    実機なしでパイプラインを試す CLI
  Omimi/                   iOS アプリ (SwiftUI)。Models/ に話者分離の Core ML モデル
  Tools/                   モデルの変換 (convert_speaker_models.py) とテストの期待値づくり
server/                    以前の自宅サーバ (今のアプリは使いません。下を参照)
docs/omi-ble-notes.md      公式リポジトリから調べた BLE プロトコルのメモ (マイク休止の仕様を含む)
```

## iOS アプリのビルド

必要なもの: Xcode 26 以降、iOS 26 以降の iPhone、[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
cd ios
cat > Config/Signing.local.xcconfig <<'EOF'
DEVELOPMENT_TEAM = あなたのTeamID
OMI_BUNDLE_ID = com.yourname.omimi
EOF
xcodegen
open Omimi.xcodeproj
```

実機を選んで実行します。初回の流れは次のとおりです。

1. 公式 Omi アプリ側でデバイスの接続を解除します。Omi は同時に 1 台にしか接続できません。
2. 「今日」の「接続の設定」から Omi を選びます。以後は自動で再接続します。
3. 「設定」で音声モデルをダウンロードします (日本語)。
4. AI でまとめるときは、「まとめ」→「ChatGPT で続ける」で接続します (ChatGPT Plus または Pro)。

## 以前の自宅サーバ (server/)

以前は録音を Mac などの自宅サーバに送り、サーバで話者分離・Whisper・AI のまとめを行っていました。今のアプリはサーバと通信しません (PC で分析するときは、アプリの「書き出し」を使います)。サーバのコードと、以前に送った録音 (`server/data/`) はそのまま残してあります。以下はサーバ単体での使い方です。


### Mac / Linux (CPU, x86 CUDA)

```bash
cd server
uv sync --extra faster-whisper
OMI_STT_MODEL=large-v3-turbo uv run omi-server serve --port 8000
uv run omi-server token        # アプリに入力するトークン (data/token に保存される)
```

ブラウザで `http://<サーバ>:8000/` を開くと、日付ごとの録音一覧、再生、検索、サーバでの再文字起こしができます。

### DGX Spark

DGX Spark (ARM64 + GB10) 向けには faster-whisper の CUDA 版が提供されていません。そのため NGC の PyTorch コンテナで transformers 版 Whisper を GPU 実行します。

```bash
cd server
docker compose up -d --build
docker compose exec omi omi-server token
```

`Dockerfile.dgx-spark` のベースイメージ (`nvcr.io/nvidia/pytorch:25.09-py3`) は、NGC カタログで arm64 対応の最新タグを確認して変更してください。

### 主な環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `OMI_DATA_DIR` | `./data` | 音声・SQLite・トークンの保存先 |
| `OMI_API_TOKEN` | (自動生成) | カンマ区切りで複数指定できます |
| `OMI_TRANSCRIBE_POLICY` | `requested` | `requested`: アプリが要求したときだけ / `always` / `never` |
| `OMI_STT_ENGINE` | `faster-whisper` | `faster-whisper` / `transformers` / `none` |
| `OMI_STT_MODEL` | エンジンごと | 例: `large-v3-turbo`, `openai/whisper-large-v3-turbo`, `kotoba-tech/kotoba-whisper-v2.0` |
| `OMI_LANGUAGES` | `ja,en` | 文字起こしの候補言語。2 つ以上なら発話ごとに自動判別します。1 つなら固定します |
| `OMI_DIARIZATION` | `1` | 話者分離・話者識別 (`0` で無効) |
| `OMI_DIARIZATION_THRESHOLD` | `0.3` | 話者分離の細かさです。小さいほど細かく分けます。分けすぎても、次の話者識別で同じ人にまとまります |
| `OMI_SPEAKER_MATCH_THRESHOLD` | `0.7` | 既知の話者と同一人物とみなす類似度です。別人が同じ話者になるなら上げ、同じ人が別の話者に分かれるなら下げます (分かれた話者は Web 画面で統合できます) |
| `OMI_SPEAKER_MIN_SECONDS` | `3` | 新しい話者として登録するのに必要な発話秒数です |
| `OMI_MODEL_DIR` | `<data>/models` | 話者分離モデルの置き場所 |
| `OMI_TIMEZONE` | サーバの地域設定 | 書き出し (`timeline/`) の日付と時刻のタイムゾーン (例: `Asia/Tokyo`) |
| `OMI_ALLOW_MODEL_DOWNLOAD` | `1` | 話者分離モデルを初回に GitHub (k2-fsa/sherpa-onnx の Releases) から取得します。SHA-256 で検証します。`0` なら手動で配置したものだけ使います (`omi-server models` で事前取得できます) |

### 保存形式

```
data/
  AGENTS.md                            エージェント向けの説明 (自動生成)
  timeline/YYYY-MM-DD.md / .jsonl      日ごとの会話のタイムライン (自動生成)
  omi.sqlite3                          メタデータ・文字起こし・話者・印
  audio/YYYY/MM/DD/<id>.opus           Ogg Opus (ffmpeg / ブラウザで再生可)
  audio/YYYY/MM/DD/<id>.json           同じ内容の JSON (DB が壊れても復元可)
```

処理は 2 本のスレッドで行います。話者分離と書き出しは速く、新しい録音から順に処理します。文字起こしは遅いので、話者分離が終わったものを後から処理します。そのため、文字起こしが遅れても話者分離は待たされません。

Mac では `server/run-mac.sh` で起動できます。Tailscale のアドレスでだけ待ち受けます。

### 通信の暗号化 (おすすめ順)

1. **Tailscale 等の VPN**: `http://100.x.y.z:8000` でも経路は WireGuard で暗号化されます。`tailscale serve` を使えば正規の HTTPS 証明書も使えます。外出先からも送信できます。
2. **自己署名証明書 + ピン留め**:
   ```bash
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
     -keyout key.pem -out cert.pem -subj "/CN=dgx-spark.local" -addext "subjectAltName=DNS:dgx-spark.local"
   uv run omi-server serve --cert cert.pem --key key.pem    # 起動時に SHA-256 が表示される
   ```
   表示された SHA-256 をアプリの「証明書 SHA-256」に貼ります。
3. **LAN 内の http**: 自宅 Wi-Fi 内だけで使う場合です。経路は暗号化されません。

## API

すべて `Authorization: Bearer <token>` が必要です。

| メソッド | パス | |
|---|---|---|
| PUT | `/api/v1/segments/{id}/audio` | Ogg Opus 本体。`X-Omi-Metadata` に base64url の JSON、`X-Content-SHA256`、`X-Omi-Transcribe: 1` を付けます |
| PUT | `/api/v1/segments/{id}/device-transcript` | 端末での文字起こし `{engine, locale, pieces:[{start,end,text,language}]}` |
| POST | `/api/v1/segments/{id}/transcribe` | サーバでの文字起こしを予約します |
| POST | `/api/v1/segments/{id}/diarize` | 話者分離をやり直します |
| PUT | `/api/v1/segments/{id}/speakers/{label}` | 録音内の話者を付け替えます `{speaker_id}` または `{name}` |
| GET | `/api/v1/segments?start=&end=` | 一覧 (ISO 8601)。文字起こしの各区間に `speaker` / `speaker_id` / `language` が付きます |
| GET | `/api/v1/segments/{id}` / `.../audio` | 詳細 / 音声 |
| GET / PATCH | `/api/v1/speakers` / `/api/v1/speakers/{id}` | 話者の一覧 / 名前の変更 `{name}` |
| POST | `/api/v1/speakers/{id}/merge` | 話者をまとめます `{into}` |
| DELETE | `/api/v1/segments/{id}` | 録音を削除します (音声・文字起こし・話者の対応) |
| POST | `/api/v1/segments/delete` | まとめて削除します `{ids}` |
| PUT / GET / DELETE | `/api/v1/markers/{id}` / `/api/v1/markers?start=&end=` | ボタンの印 `{kind: highlight\|split\|memo, at, device_id}` |
| GET | `/api/v1/search?q=` | 文字起こしの部分一致検索 |
| PUT | `/api/v1/segments/{id}/utterances` | 時間の範囲の話者を指定します `{start, end, speaker_id \| name \| unknown}` |
| POST | `/api/v1/segments/{id}/reassign` | 録音の中の、ある話者のところを付け替えます `{from_speaker_id, speaker_id \| name \| unknown}` |
| PUT | `/api/v1/utterances/{id}` | 発話の話者を指定・確認します `{speaker_id \| name \| unknown \| confirm}` |
| GET | `/api/v1/segments/{id}/clip?start=&end=` | 発話の音声 (WAV) |
| GET | `/api/v1/speakers/{id}/utterances?filter=suspicious\|all\|confirmed` | 話者の発話 (その人らしくないもの) |
| POST | `/api/v1/speakers/train` | 名前を付けた話者を学習し直します |
| POST | `/api/v1/speakers/{id}/assign` | 名前のない声をすべての録音でまとめて決めます `{name \| speaker_id \| unknown}` (unknown は「その他」にする) |
| GET | `/api/v1/stats?days=30` | 蓄積の集計と、夜の整理の進み具合 (`pipeline`) |
| GET | `/api/v1/notes` / `/api/v1/notes/{name}` | AI のまとめ (`data/notes/*.md`) の一覧 / 本文 |
| GET / POST | `/api/v1/ai/status` / `/api/v1/ai/connect` / `/api/v1/ai/callback` / `/api/v1/ai/disconnect` | ChatGPT との接続 (Sign in with ChatGPT) |
| GET / PUT | `/api/v1/ai/models` / `/api/v1/ai/model` | 使うモデル |
| POST | `/api/v1/ai/run` | AI で整理する `{day}` (進み具合は `/api/v1/ai/status` の `job`) |
| GET / POST / PUT / DELETE | `/api/v1/vocabulary` / `/api/v1/vocabulary/{id}` | 用語集 `{term, reading, aliases, note}` |
| GET | `/guide.md` | 使い方 (認証なし) |

## 開発・テスト

```bash
# コアライブラリ (macOS)
cd ios/OmiKit && swift test
OMI_E2E=1 swift test --filter EndToEnd   # say で作った日本語音声を BLE 模擬 → 保存 → Apple 文字起こし

# 実機なしでパイプラインを試す
swift run omikit-cli simulate talk.aiff /tmp/phone --segment-seconds 60 --loss 0.01 --pause 5:12
swift run omikit-cli transcribe /tmp/phone --locale ja-JP,en-US
swift run omikit-cli speakers talk.opus --models ../Omimi/Models   # iPhone と同じ話者分離 (Core ML)

# サーバ
cd server && uv run pytest
```

## 制限と今後

- Omi 本体の SD カードに残る録音 (iPhone と離れている間の分) は使いません。
- バックグラウンドで Apple の文字起こしが使えない場合は「保留」のまま残し、アプリが前面に戻ったときか、充電中のバックグラウンド処理で再試行します。
- 端末での文字起こしはセグメントが閉じてから行うため、リアルタイム表示はありません。
- 話者分離・識別は実際の人の声ではまだ調整していません。合成音声 (macOS の `say`) の 3 人の会話では、正しく分離・識別できることを確認しました。話者が混ざる場合や、同じ人が分かれる場合は、上の 2 つのしきい値を調整してください。
- 話者識別は、声の特徴が録音条件で変わると別人と判定されることがあります。その場合は会話の中で直すか、「設定 → 話者と声の学習」で名前を変えて統合してください (同じ名前にするとまとまります)。
- 端末の文字起こしの言語判別は日本語と英語で確認しました。他の言語の組み合わせは未確認です。
- 印 (ボタン操作) は Omi と接続中のみ記録されます。圏外でデバイスに録音している間の操作は残りません。
- 「AI で整理」を使うと、選んだ日 (時間帯) の会話の内容が OpenAI に送られます。外に出したくない日は使わないでください。書き出したデータを PC のローカル LLM で分析することもできます。
- ユーザが App スイッチャーでアプリを終了すると、iOS は BLE での再起動を行いません。その間、デバイスは SD カードに録音します。
