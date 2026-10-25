import OmiKit
import OmiTranscription
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var locales: [Locale] = []
    @State private var storageBytes: Int64 = 0
    @State private var showDevice = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Button { showDevice = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.stream?.deviceName ?? model.savedDeviceName ?? "Omi を登録する")
                                    .foregroundStyle(Palette.ink)
                                Text(model.linkState.label).font(.footnote).foregroundStyle(Palette.inkSoft)
                            }
                            Spacer()
                            if let b = model.battery { Text("\(b)%").monospacedDigit().foregroundStyle(Palette.inkSoft) }
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.inkSoft)
                        }
                    }
                    Toggle("録音する", isOn: Binding(get: { settings.recordingEnabled }, set: { model.setRecording($0) }))
                    Stepper("1 つの録音は最長 \(settings.segmentMinutes) 分", value: $settings.segmentMinutes, in: 1...30)
                } header: {
                    header("Omi")
                } footer: {
                    Text("話し終えて 30 秒たつか、最長の時間になると録音を区切ります。")
                }

                Section {
                    Picker("ランプ", selection: $settings.ledBrightness) {
                        Text("消す").tag(0)
                        Text("暗め").tag(10)
                        Text("標準").tag(50)
                    }
                    Picker("マイクの感度", selection: $settings.micGain) {
                        Text("本体の設定のまま").tag(-1)
                        Text("低め (電池優先)").tag(4)
                        Text("標準").tag(6)
                        Text("高め (遠くの声も拾う)").tag(8)
                    }
                    if let rate = model.batteryLog.drainPerHour() {
                        LabeledContent("電池の減り", value: String(format: "1 時間に %.1f%%", rate))
                    }
                } header: {
                    header("電池")
                } footer: {
                    Text("Omi のランプは接続中ずっと点いています。消すと電池が長持ちします (状態はこのアプリで確かめられます)。マイクの感度を下げると物音でマイクが起きにくくなり電池が持ちますが、遠くの声は拾いにくくなります。どちらも Omi 本体に保存されます。")
                }

                Section {
                    Toggle("iPhone で文字起こしする", isOn: $settings.deviceTranscription)
                    Picker("主な言語", selection: $settings.localeID) {
                        if locales.isEmpty { Text(settings.localeID).tag(settings.localeID) }
                        ForEach(locales, id: \.self) { l in Text(localeName(l)).tag(l.identifier(.bcp47)) }
                    }
                    Picker("自動で切り替える言語", selection: $settings.secondaryLocaleID) {
                        Text("なし").tag("")
                        if locales.isEmpty && !settings.secondaryLocaleID.isEmpty {
                            Text(settings.secondaryLocaleID).tag(settings.secondaryLocaleID)
                        }
                        ForEach(locales.filter { $0.identifier(.bcp47) != settings.localeID }, id: \.self) { l in
                            Text(localeName(l)).tag(l.identifier(.bcp47))
                        }
                    }
                    modelRow
                    Button("失敗した文字起こしをやり直す") { model.transcription.retryFailed() }
                } header: {
                    header("文字起こし")
                } footer: {
                    Text("Apple の音声認識を iPhone の中で使います。音声は iPhone の外に出ません。2 つの言語の認識を同時に動かし、発言ごとに確からしい方を選びます。")
                }

                Section {
                    Toggle("iPhone で話者を聞き分ける", isOn: $settings.deviceSpeakers)
                    if settings.deviceSpeakers {
                        Text(model.deviceSpeakerStatus).font(.footnote).foregroundStyle(Palette.inkSoft)
                        if let speed = model.deviceSpeakerSpeed {
                            LabeledContent("処理の速さ", value: speed)
                        }
                    }
                    LabeledContent("名前を当てる声", value: model.voiceLibraryDescription)
                } header: {
                    header("話者の聞き分け")
                } footer: {
                    Text("話者の区切りと声の特徴の AI モデルを iPhone の中で動かします。音声は iPhone の外に出ません。充電中とアプリを開いているときに進みます。名前は、会話の中で直した・付けた名前から学習した声で当てます。")
                }

                Section {
                    NavigationLink {
                        SpeakersView()
                    } label: {
                        LabeledContent("話者と声の学習") {
                            let n = model.people.reduce(0) { $0 + $1.suspicious }
                            if n > 0 { Text("確認したい発話 \(n)").foregroundStyle(Palette.shu) }
                        }
                    }
                    NavigationLink {
                        VocabularyView()
                    } label: {
                        LabeledContent("用語集") {
                            if !model.vocabulary.isEmpty { Text("\(model.vocabulary.count) 語") }
                        }
                    }
                } header: {
                    header("話者と用語")
                } footer: {
                    Text("名前を付けた人の声を iPhone が学習し、次からの録音で名前を当てます。用語集は文字起こしのヒント・表示の補正・AI への添付に使います。")
                }

                Section {
                    LabeledContent("iPhone 内の録音", value: "\(model.segments.count) 件  \(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))")
                    NavigationLink("音声と文字起こしを書き出す") { ExportView() }
                } header: {
                    header("保存と書き出し")
                } footer: {
                    Text("録音は iPhone の中で暗号化され、iCloud のバックアップには入りません。PC で分析するときは、期間を選んで音声と文字起こしを書き出し、AirDrop や「ファイル」で渡します。")
                }

                Section {
                    LabeledContent("Omimi", value: appVersion)
                    Text("外部のサービスや解析ツールは使っていません。通信するのは Omi (Bluetooth) と Apple の音声認識モデルの配信だけです。「まとめ → AI で整理」を使ったときだけ、選んだ日の文字起こしを OpenAI (ChatGPT) に送ります。話者の聞き分けのモデルはアプリに入っています。")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                } header: {
                    header("このアプリについて")
                }
            }
            .paperBackground()
            .listRowBackground(Palette.surface)
            .navigationTitle("設定")
            .sheet(isPresented: $showDevice) { DeviceSheet() }
            .task {
                locales = await AppleSpeechTranscriber.supportedLocales().sorted { $0.identifier < $1.identifier }
                storageBytes = model.storageBytes
                await model.transcription.refreshModelState()
                await model.refreshPeople()
            }
            .onChange(of: settings.localeID) { Task { await model.transcription.refreshModelState() } }
            .onChange(of: settings.secondaryLocaleID) { Task { await model.transcription.refreshModelState() } }
            .onChange(of: settings.segmentMinutes) { model.settingsChanged() }
            .onChange(of: settings.ledBrightness) { model.settingsChanged() }
            .onChange(of: settings.micGain) { model.settingsChanged() }
            .onChange(of: settings.deviceTranscription) { model.settingsChanged() }
            .onChange(of: settings.deviceSpeakers) { _, on in
                if on { model.speakerQueue.kick() } else { model.speakerQueue.cancel() }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Typeface.mincho(17, relativeTo: .headline)).foregroundStyle(Palette.ink)
            .textCase(nil)
    }

    private func localeName(_ l: Locale) -> String {
        Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    @ViewBuilder private var modelRow: some View {
        switch model.modelState {
        case .installed:
            LabeledContent("音声認識モデル", value: "準備できています")
        case .notInstalled, .unknown:
            Button("音声認識モデルをダウンロード") { Task { await model.transcription.installModel() } }
        case .downloading(let p):
            LabeledContent("音声認識モデル") { ProgressView(value: p).frame(width: 120) }
        case .unsupported:
            LabeledContent("音声認識モデル", value: "この言語は使えません")
        case .failed(let msg):
            VStack(alignment: .leading) {
                Button("音声認識モデルをもう一度ダウンロード") { Task { await model.transcription.installModel() } }
                Text(msg).font(.footnote).foregroundStyle(Palette.shu)
            }
        }
    }
}
