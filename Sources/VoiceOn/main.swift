import Cocoa
import CoreGraphics
import AVFoundation
import Speech

// =============================================================================
// VoiceOn — 「英数」キー長押し中だけマイクで音声認識（Speechフレームワーク）し、
//           離した時点でカーソル位置に認識結果を打ち込むメニューバー常駐アプリ。
//
//   - 認識結果を「文字キー入力」として送り込むため、ターミナル等ほぼ全アプリで動く
//   - 録音の開始/停止を完全制御（純粋な push-to-talk）
//   - オンデバイス認識を使うので完全無料・オフライン・通信なし
//   - 録音中はマウスカーソルに音量連動インジケータ（またはGIF）を表示
//
// 必要な権限: アクセシビリティ / マイク / 音声認識
// =============================================================================

// MARK: - 設定

/// 録音インジケータの表示位置
enum IndicatorPosition {
    case topCenter      // 画面上・中央（ノッチ風）
    case bottomCenter   // 画面下・中央
    case bottomLeft     // 左下
    case topRight       // 右上（メニューバー寄り）
    case mouse          // マウス追従
}

enum Config {
    static let triggerKeycode: Int64 = 102      // 英数 (kVK_JIS_Eisu)
    static let holdThresholdMs: Int = 200       // これ以上の長押しで録音開始
    static let localeIdentifier = "ja-JP"

    // ⌘ダブルタップ＆ホールド（US配列でも使える汎用トリガー）
    static let cmdGestureEnabled = true
    static let cmdDoubleTapWindowMs = 400       // 1回目タップ→2回目押下までの猶予
    static let cmdTapMaxMs = 350                // タップとみなす最大押下時間
    /// 表示中セグメントがこの文字数以上で先頭が変わった場合のみ「新セグメント」と判定し、
    /// 前を確定して追記する（消さない）。これ未満の短い断片は言い直しとみなして置き換え、
    /// 二重登録を防ぐ。
    static let segmentMinChars: Int = 3

    // --- 録音中のマウスカーソル表示 ---
    /// カーソルに重ねるアニメGIF等のファイルパス。指定すればそれを表示、
    /// nil なら下の「点滅する丸」にフォールバックする。
    static let cursorAnimationFile: String? = nil   // 例: "~/path/to/cursor.gif" の絶対パス
    static let animationSize = NSSize(width: 48, height: 48)

    // 録音中インジケータ（Apple純正風・上品）
    static let indicatorPosition: IndicatorPosition = .bottomLeft   // 表示位置
    static let levelGain: Float = 28                   // 音量感度（大きいほど小さな音で反応）
    static let levelCurve: Float = 0.6                  // <1 で低音量を持ち上げる（小さいほど敏感）
    static let cursorRingColor: NSColor = .white        // 呼吸するリング（明暗どちらでも見えるよう影付き）
    static let cursorCoreColor: NSColor = .systemRed    // 中心の録音ドット
    static let cursorBaseDiameter: CGFloat = 30         // リング基準径（音量で拡大）
}

let kSynthMagic: Int64 = 0x564F_4943 // "VOIC"

// MARK: - 音声認識

final class SpeechEngine {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Config.localeIdentifier))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 確定済みテキスト（区切りで確定した分を貯める）
    private var committedText = ""
    /// 現在のセグメントの最新テキスト
    private var segmentText = ""
    private var finishing = false
    private(set) var isRunning = false
    private var smoothedLevel: Float = 0

    var onError: ((String) -> Void)?
    /// マイク音量（0〜1）をリアルタイムに通知
    var onLevel: ((Float) -> Void)?
    /// 認識中の累計文字数をリアルタイムに通知（メインスレッド）
    var onCharCount: ((Int) -> Void)?

    func start() {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onError?("音声認識が利用できません（言語設定/接続を確認）")
            return
        }

        committedText = ""
        segmentText = ""
        finishing = false
        smoothedLevel = 0

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)
            let lv = self.computeLevel(buffer)
            if let cb = self.onLevel { DispatchQueue.main.async { cb(lv) } }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("マイク開始に失敗: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            request = nil
            isRunning = false
            return
        }

        isRunning = true
        startRecognitionTask()
    }

    /// 認識リクエスト/タスクを作成（区切り後の再スタートでも使う）
    private func startRecognitionTask() {
        guard let recognizer = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true   // 句読点の自動付与
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async { self.handleResult(text: text, isFinal: isFinal) }
            }
            if error != nil {
                DispatchQueue.main.async { self.finalizeSession() }
            }
        }
    }

    /// ※ メインスレッドで呼ばれる。録音中は挿入せず、テキストを貯めるだけ。
    private func handleResult(text: String, isFinal: Bool) {
        guard isRunning else { return }

        if !text.isEmpty {
            // 共通プレフィックスが0かつ現セグメントが十分長い＝新セグメント → 前を確定。
            // それ以外（言い直し/伸長）は現セグメントを置き換え。
            let common = Self.commonPrefixCount(segmentText, text)
            if common == 0 && segmentText.count >= Config.segmentMinChars {
                committedText += segmentText   // 前のセグメントを確定
            }
            segmentText = text                 // 現セグメントを更新
            onCharCount?(committedText.count + segmentText.count)
        }

        if isFinal {
            if finishing {
                finalizeSession()
            } else {
                // 区切り（無音）でセグメント確定 → 認識を再スタートして継続
                committedText += segmentText
                segmentText = ""
                task = nil
                request = nil
                startRecognitionTask()
            }
        }
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        var i = 0
        while i < aa.count, i < bb.count, aa[i] == bb[i] { i += 1 }
        return i
    }

    func stop() {
        guard isRunning else { return }
        finishing = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()

        // 最終結果が来ない場合の保険（2秒後に確定）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finalizeSession()
        }
    }

    /// 録音終了・確定テキストを一括挿入してリセット（多重呼び出しに安全）
    private func finalizeSession() {
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.finishing = false
            self.task?.cancel()
            self.task = nil
            self.request = nil
            let finalText = self.committedText + self.segmentText
            self.committedText = ""
            self.segmentText = ""
            if !finalText.isEmpty {
                TextInserter.insert(finalText)   // 離した瞬間にまとめて挿入
            }
        }
    }

    /// バッファのRMSから音量レベル(0〜1)を算出。速いアタック・遅いディケイで平滑化。
    /// ※ オーディオスレッドで呼ばれる
    private func computeLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return smoothedLevel }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return smoothedLevel }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = sqrtf(sum / Float(n))
        let raw = min(1, rms * Config.levelGain)
        let target = powf(raw, Config.levelCurve)   // 低音量を持ち上げて感度UP
        smoothedLevel = max(target, smoothedLevel * 0.85)
        return smoothedLevel
    }
}

// MARK: - テキスト挿入（CGEvent で Unicode を打ち込む）

enum TextInserter {
    static func insert(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: kSynthMagic)
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - トリガー（英数 長押し / 短押しは透過）

final class TriggerController {
    private var holdFired = false
    private var pressGeneration = 0
    let engine = SpeechEngine()
    var onStateChange: ((Bool) -> Void)?

    // --- ⌘ ダブルタップ＆ホールド用 ---
    private var cmdDown = false
    private var cmdDownTime = Date()
    private var dirtyDuringCmd = false        // ⌘押下中に他キー/他修飾が入った＝ショートカット
    private var awaitingSecondUntil: Date?    // 1回目タップ後、2回目押下を待つ期限
    private var cmdHoldGen = 0
    private var cmdActive = false             // ⌘ホールドで録音中

    func handleKeyDown(keycode: Int64, autorepeat: Bool) -> Bool {
        // ⌘押下中に通常キーが押されたら、それはショートカット操作なのでジェスチャを汚す
        if cmdDown { dirtyDuringCmd = true }

        guard keycode == Config.triggerKeycode else { return false }
        if autorepeat { return true }

        holdFired = false
        pressGeneration += 1
        let gen = pressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Config.holdThresholdMs)) { [weak self] in
            guard let self = self, gen == self.pressGeneration, !self.holdFired else { return }
            self.holdFired = true
            self.onStateChange?(true)
            self.engine.start()
        }
        return true
    }

    /// ⌘の状態変化を処理（command=⌘押下中か, extra=他の修飾キーが併用されているか）
    func handleFlags(command: Bool, extra: Bool) {
        guard Config.cmdGestureEnabled else { return }
        let now = Date()

        if command && !cmdDown {
            // ⌘ダウン
            cmdDown = true
            cmdDownTime = now
            dirtyDuringCmd = extra
            if let deadline = awaitingSecondUntil, now <= deadline, !extra {
                // 2回目の押下 → 長押し判定タイマー開始
                awaitingSecondUntil = nil
                cmdHoldGen += 1
                let g = cmdHoldGen
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Config.holdThresholdMs)) { [weak self] in
                    guard let self = self, self.cmdDown, g == self.cmdHoldGen,
                          !self.dirtyDuringCmd, !self.cmdActive else { return }
                    self.cmdActive = true
                    self.onStateChange?(true)
                    self.engine.start()
                }
            } else {
                awaitingSecondUntil = nil   // 1回目候補（離した時に判定）
            }
        } else if command && cmdDown {
            // ⌘押下中に他修飾が増えた → ショートカット扱い
            if extra { dirtyDuringCmd = true }
        } else if !command && cmdDown {
            // ⌘アップ
            cmdDown = false
            let duration = now.timeIntervalSince(cmdDownTime)
            if cmdActive {
                cmdActive = false
                onStateChange?(false)
                engine.stop()
                awaitingSecondUntil = nil
            } else if !dirtyDuringCmd && duration <= Double(Config.cmdTapMaxMs) / 1000.0 {
                // クリーンな短タップ → 2回目を待つ
                awaitingSecondUntil = now + Double(Config.cmdDoubleTapWindowMs) / 1000.0
            } else {
                awaitingSecondUntil = nil
            }
        }
    }

    func handleKeyUp(keycode: Int64) -> Bool {
        guard keycode == Config.triggerKeycode else { return false }
        pressGeneration += 1
        if holdFired {
            holdFired = false
            onStateChange?(false)
            engine.stop()
        } else {
            emitTriggerTap()
        }
        return true
    }

    private func emitTriggerTap() {
        let src = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(Config.triggerKeycode)
        for keyDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: keyDown)
            e?.flags = []
            e?.setIntegerValueField(.eventSourceUserData, value: kSynthMagic)
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - マウスカーソル上のインジケータ（録音中）

/// カーソル追従ビューの共通インターフェース
protocol CursorEffect: AnyObject {
    func start()
    func stop()
}

/// アニメGIF等を再生するビュー
final class GifEffectView: NSImageView, CursorEffect {
    func start() { animates = true }
    func stop() { animates = false }
}

/// Apple純正風の上品な録音インジケータ。
/// 穏やかに呼吸するリング＋中心の小さな録音ドット＋柔らかいグロー。音量でそっと反応。
final class LevelDotView: NSView, CursorEffect {
    /// 0（静か）〜1（大きい）。音声側から更新される目標値。
    var level: CGFloat = 0

    private let ringLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private let countLayer = CATextLayer()
    private var timer: Timer?
    private var rippleTimer: Timer?
    private var displayedLevel: CGFloat = 0
    private var phase: Double = 0
    private var lastTick = Date()
    private let backingScale = NSScreen.main?.backingScaleFactor ?? 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 呼吸するリング（白＋柔らかい影で明暗どちらの背景でも視認）
        let ringD = Config.cursorBaseDiameter
        ringLayer.bounds = CGRect(x: 0, y: 0, width: ringD, height: ringD)
        ringLayer.position = center
        ringLayer.path = CGPath(ellipseIn: ringLayer.bounds, transform: nil)
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = Config.cursorRingColor.cgColor
        ringLayer.lineWidth = 3.5
        ringLayer.contentsScale = scale
        ringLayer.shadowColor = NSColor.black.cgColor
        ringLayer.shadowOpacity = 0.5
        ringLayer.shadowRadius = 5
        ringLayer.shadowOffset = .zero
        layer?.addSublayer(ringLayer)

        // 中心の録音ドット
        let coreD: CGFloat = 10
        coreLayer.bounds = CGRect(x: 0, y: 0, width: coreD, height: coreD)
        coreLayer.position = center
        coreLayer.path = CGPath(ellipseIn: coreLayer.bounds, transform: nil)
        coreLayer.fillColor = Config.cursorCoreColor.cgColor
        coreLayer.contentsScale = scale
        coreLayer.shadowColor = Config.cursorCoreColor.cgColor
        coreLayer.shadowOpacity = 0.6
        coreLayer.shadowRadius = 3
        coreLayer.shadowOffset = .zero
        layer?.addSublayer(coreLayer)

        // 文字数ラベル（リングの下）
        countLayer.string = "0字"
        countLayer.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        countLayer.fontSize = 15
        countLayer.alignmentMode = .center
        countLayer.foregroundColor = NSColor.white.cgColor
        countLayer.contentsScale = scale
        countLayer.shadowColor = NSColor.black.cgColor
        countLayer.shadowOpacity = 0.7
        countLayer.shadowRadius = 3
        countLayer.shadowOffset = .zero
        countLayer.frame = CGRect(x: 0, y: 10, width: bounds.width, height: 20)
        layer?.addSublayer(countLayer)
    }

    func setCount(_ count: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countLayer.string = "\(count)字"
        CATransaction.commit()
    }

    func start() {
        level = 0; displayedLevel = 0; phase = 0; lastTick = Date()
        setCount(0)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 周期的に波紋を出して目を引く
        spawnRipple()
        let rt = Timer(timeInterval: 1.3, repeats: true) { [weak self] _ in self?.spawnRipple() }
        RunLoop.main.add(rt, forMode: .common)
        rippleTimer = rt
    }

    func stop() {
        timer?.invalidate(); timer = nil
        rippleTimer?.invalidate(); rippleTimer = nil
    }

    /// 外側へ広がってフェードする波紋リングを1つ出す
    private func spawnRipple() {
        guard let host = layer else { return }
        let d = Config.cursorBaseDiameter
        let r = CAShapeLayer()
        r.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        r.position = CGPoint(x: bounds.midX, y: bounds.midY)
        r.path = CGPath(ellipseIn: r.bounds, transform: nil)
        r.fillColor = NSColor.clear.cgColor
        r.strokeColor = Config.cursorRingColor.cgColor
        r.lineWidth = 2.5
        r.contentsScale = backingScale
        r.shadowColor = NSColor.black.cgColor
        r.shadowOpacity = 0.4
        r.shadowRadius = 3
        host.insertSublayer(r, below: ringLayer)

        let dur: CFTimeInterval = 1.6
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 3.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fade]
        group.duration = dur
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        r.add(group, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { r.removeFromSuperlayer() }
    }

    private func tick() {
        let now = Date()
        let dt = min(0.05, now.timeIntervalSince(lastTick))
        lastTick = now

        // 音量はなめらかに追従（上品さのため強めに平滑化）
        displayedLevel += (level - displayedLevel) * 0.18
        // ゆっくりした呼吸（約2.4秒周期）
        phase += dt * (2 * Double.pi / 2.4)
        let breathe = CGFloat(sin(phase) * 0.5 + 0.5)   // 0〜1
        let lv = max(0, min(1, displayedLevel))

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 自前の平滑化を使う（暗黙アニメ無効）

        // リング：呼吸＋音量でそっと拡大、わずかに濃く、グローが強まる
        let ringScale = 1.0 + breathe * 0.08 + lv * 1.1
        ringLayer.transform = CATransform3DMakeScale(ringScale, ringScale, 1)
        ringLayer.opacity = Float(0.55 + breathe * 0.15 + lv * 0.4)
        ringLayer.shadowRadius = 4 + lv * 8

        // 中心ドット：呼吸でほのかに明滅
        coreLayer.opacity = Float(0.7 + breathe * 0.3)
        let coreScale = 1.0 + lv * 0.5
        coreLayer.transform = CATransform3DMakeScale(coreScale, coreScale, 1)

        CATransaction.commit()
    }
}

/// 透明・クリック透過パネルをマウスカーソルに追従させる
final class CursorIndicator {
    private var panel: NSPanel?
    private var effectView: (NSView & CursorEffect)?
    private var levelView: LevelDotView?   // 音量連動ドットのとき設定
    private var tracker: Timer?
    private var panelSize = NSSize(width: 48, height: 48)

    /// 0〜1 の音量レベルを反映
    func setLevel(_ level: Float) {
        levelView?.level = CGFloat(level)
    }

    /// 認識中の文字数を反映
    func setCharCount(_ count: Int) {
        levelView?.setCount(count)
    }

    func show() {
        if panel == nil { setup() }
        // 表示するたびに全Space表示・最前面設定を貼り直す（Space/アプリ切替で外れる対策）
        panel?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel?.level = .statusBar
        reposition()
        panel?.orderFrontRegardless()
        effectView?.start()
        // マウス追従のときだけ毎フレーム位置更新。固定表示なら不要。
        if Config.indicatorPosition == .mouse {
            tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.reposition()
            }
        }
    }

    func hide() {
        tracker?.invalidate(); tracker = nil
        effectView?.stop()
        panel?.orderOut(nil)
    }

    private func setup() {
        // アニメファイルが指定・読込できれば GIF、ダメなら音量連動ドット
        let view: (NSView & CursorEffect)
        if let path = Config.cursorAnimationFile, let image = NSImage(contentsOfFile: path) {
            panelSize = Config.animationSize
            let gif = GifEffectView(frame: NSRect(origin: .zero, size: panelSize))
            gif.image = image
            gif.imageScaling = .scaleProportionallyUpOrDown
            gif.animates = false
            view = gif
            levelView = nil
        } else {
            panelSize = NSSize(width: 130, height: 130)
            let dot = LevelDotView(frame: NSRect(origin: .zero, size: panelSize))
            view = dot
            levelView = dot
        }

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = view
        panel = p
        effectView = view
    }

    private func reposition() {
        guard let panel = panel else { return }
        let w = panelSize.width, h = panelSize.height

        if Config.indicatorPosition == .mouse {
            let m = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: m.x - w / 2, y: m.y - h / 2))
            return
        }

        // 今いる画面（マウスのある画面）に出す。別ディスプレイでも見える側に表示される。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame else { return }
        let ringFromTop: CGFloat = 30   // 画面上端からリング中心まで
        let margin: CGFloat = 12
        var origin = NSPoint(x: f.midX - w / 2, y: f.maxY - ringFromTop - h / 2)
        switch Config.indicatorPosition {
        case .topCenter:
            break
        case .bottomCenter:
            origin = NSPoint(x: f.midX - w / 2, y: f.minY + margin)
        case .bottomLeft:
            origin = NSPoint(x: f.minX + margin, y: f.minY + margin)
        case .topRight:
            origin = NSPoint(x: f.maxX - w - margin, y: f.maxY - ringFromTop - h / 2)
        case .mouse:
            break
        }
        panel.setFrameOrigin(origin)
    }
}

// MARK: - イベントタップ

let controller = TriggerController()
var eventTap: CFMachPort?

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == kSynthMagic {
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .keyDown:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if controller.handleKeyDown(keycode: kc, autorepeat: repeated) { return nil }
    case .keyUp:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if controller.handleKeyUp(keycode: kc) { return nil }
    case .flagsChanged:
        let raw = event.flags.rawValue
        let command = raw & CGEventFlags.maskCommand.rawValue != 0
        let extra = raw & (CGEventFlags.maskShift.rawValue
                           | CGEventFlags.maskControl.rawValue
                           | CGEventFlags.maskAlternate.rawValue
                           | CGEventFlags.maskSecondaryFn.rawValue) != 0
        controller.handleFlags(command: command, extra: extra)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func startEventTap() -> Bool {
    let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: eventTapCallback,
        userInfo: nil
    ) else { return false }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    // ウォッチドッグ: タップが無効化されたら自動で再有効化（安全網）
    let watchdog = Timer(timeInterval: 1.0, repeats: true) { _ in
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    RunLoop.main.add(watchdog, forMode: .common)
    return true
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cursorIndicator = CursorIndicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        controller.onStateChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let btn = self.statusItem.button
                btn?.image = self.symbolImage(active ? "mic.fill" : "mic")
                btn?.contentTintColor = active ? .systemRed : nil
                if active { self.cursorIndicator.show() } else { self.cursorIndicator.hide() }
            }
        }
        controller.engine.onLevel = { [weak self] level in
            self?.cursorIndicator.setLevel(level)   // onLevel は既にメインスレッド
        }
        controller.engine.onCharCount = { [weak self] count in
            self?.cursorIndicator.setCharCount(count)
        }
        controller.engine.onError = { msg in
            DispatchQueue.main.async {
                let a = NSAlert(); a.messageText = "音声認識エラー"; a.informativeText = msg; a.runModal()
            }
        }

        requestPermissions { [weak self] in
            guard let self = self else { return }
            guard AXIsProcessTrusted() else {
                self.showAccessibilityAlert(); return
            }
            if !startEventTap() {
                let a = NSAlert(); a.messageText = "キーボード監視を開始できませんでした"
                a.informativeText = "アクセシビリティ権限を確認して再起動してください。"; a.runModal()
            }
        }
    }

    private func requestPermissions(_ done: @escaping () -> Void) {
        // アクセシビリティはプロンプトのみ（付与は設定アプリで）
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        SFSpeechRecognizer.requestAuthorization { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done() }
            }
        }
    }

    /// メニューバー用の SF Symbol 画像（テンプレート＝ダーク/ライト自動対応）
    private func symbolImage(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceOn")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = symbolImage("mic")
        let menu = NSMenu()
        menu.addItem(withTitle: "VoiceOn — 「英数」長押しで音声入力", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "アクセシビリティ設定を開く", action: #selector(openAX), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAccessibilityAlert() {
        let a = NSAlert()
        a.messageText = "アクセシビリティ権限が必要です"
        a.informativeText = "システム設定 > プライバシーとセキュリティ > アクセシビリティ で VoiceOn を許可し、再起動してください。"
        a.addButton(withTitle: "設定を開く"); a.addButton(withTitle: "閉じる")
        if a.runModal() == .alertFirstButtonReturn { openAX() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
