# Optimal architecture for a local Whisper dictation tool on macOS

**Go native Swift with WhisperKit.** After evaluating five tech stack options, benchmarking three Whisper runtimes on Apple Silicon, and analyzing a dozen existing open-source projects, the clear winner for a single-developer macOS dictation tool is a **pure Swift app using WhisperKit for transcription, SwiftUI MenuBarExtra for the UI, and the large-v3-turbo model**. This architecture delivers the best reliability, native integration, and long-term maintainability — the three things a power-user personal tool needs most. The entire app compiles to a single `.app` bundle with no Python packaging headaches, no C++ bridging complexity, and no subprocess management. A working prototype is achievable in 3–5 days.

---

## The Whisper runtime decision: WhisperKit wins on M1

Three serious contenders exist for running Whisper locally on Apple Silicon: **whisper.cpp**, **MLX Whisper**, and **WhisperKit**. Each targets different hardware paths on the M1 — Metal GPU, MLX unified compute, and CoreML Neural Engine respectively.

**whisper.cpp** (46.7k GitHub stars, MIT license) is the most mature and widely deployed. It supports Metal GPU acceleration by default and optional CoreML for the encoder, which together yield roughly **8–12× real-time performance** on M1 Pro. The `large-v3-turbo` model with Q5_0 quantization transcribes 10 minutes of audio in approximately **90–120 seconds** on M1 Pro. Memory usage sits around **3–4 GB** for the quantized turbo model, fitting comfortably in 16 GB unified memory. The project offers official Swift Package Manager support via `whisper.spm` and a precompiled XCFramework.

**MLX Whisper** is Apple's own ML framework approach — pure Python, dead-simple (`pip install mlx-whisper`, two lines to transcribe), and roughly **30–40% faster** than whisper.cpp on identical models in batch mode. However, it uses Metal GPU only (no Neural Engine), has disappointing streaming performance on M1, and requires Python packaging — a dealbreaker for a native menu bar app.

**WhisperKit** (5,669 stars, MIT license, by Argmax) is purpose-built for Apple platforms. It runs entirely through CoreML, leveraging the **Apple Neural Engine** for maximum efficiency. Published at ICML 2025, it achieves **0.46s latency with 2.2% WER** — matching cloud-based systems. It provides full streaming transcription, voice activity detection, word-level timestamps, and an async Swift API that reduces transcription to two lines of code. The tradeoff: it requires **macOS 14+ (Sonoma)**, which is reasonable for a new personal tool.

| Runtime | Language | Acceleration | M1 Pro speed (10 min audio) | Memory | Streaming | Complexity |
|---------|----------|-------------|---------------------------|--------|-----------|------------|
| whisper.cpp | C/C++ (Swift bindings) | Metal + CoreML | ~90–120s | ~3–4 GB | Yes (example app) | Medium (C++ bridging) |
| MLX Whisper | Python | Metal (MLX) | ~80–100s | ~4–5 GB | Poor on M1 | Low (Python) |
| WhisperKit | Swift | CoreML + Neural Engine | ~90–110s | ~3–4 GB | Yes (native) | **Low (pure Swift)** |
| faster-whisper | Python | **CPU only on Mac** | ~6× slower | ~5 GB | Yes | Low but slow |

**The recommendation is WhisperKit** for the primary build, with whisper.cpp as a proven fallback if you need broader macOS version support or custom GGML model formats. WhisperKit eliminates all C++/bridging complexity, provides the cleanest Swift API, and is battle-tested in commercial apps like superwhisper (which uses Argmax's SDK) and Voxpen.

## The model sweet spot: large-v3-turbo Q5_0

The **large-v3-turbo** model is the clear choice for English dictation. It has only **4 decoder layers** (vs 32 in large-v3) while sharing the identical encoder, resulting in **6× faster inference** with virtually identical accuracy — **7.75% WER vs 7.88%** for large-v3 on benchmarks. It also hallucinates less than the full large-v3 on clean single-speaker audio.

For whisper.cpp users, Q5_0 quantization reduces model size from ~1.5 GB to **~900 MB** on disk while preserving transcription accuracy (WER increases by only 0.01–0.02 on clean speech). WhisperKit auto-downloads the optimal model variant for your device and handles CoreML compilation on first launch. Expect a **30–60 second cold start** when the model first loads, after which transcription is near-instantaneous for dictation-length audio.

For long-form audio handling (1–10 minute dictation sessions), both WhisperKit and whisper.cpp process 30-second windows sequentially, using the previous transcription as context for the next chunk. Enable **voice activity detection** (built into both) to skip silence and reduce hallucination. Sequential processing (not parallel chunking) gives the best accuracy for dictation since it maintains coherence across chunks.

## Why pure Swift beats every other tech stack

Five tech stack options were evaluated against the stated priority ordering: reliability > performance > build speed > code elegance.

**Option A — Swift + whisper.cpp**: Proven by VoiceInk (~3,700 stars) and OpenSuperWhisper (~620 stars). Excellent macOS integration but requires C++ bridging via cmake submodule or the whisper.spm package. Build complexity is moderate.

**Option B — Pure Python**: Fastest to prototype but worst macOS integration. The `rumps` library produces basic menu bar apps with no rich UI. `pynput` hotkeys are unreliable on macOS. Packaging with py2app or PyInstaller creates 200–500 MB bundles and constant dependency headaches. **Not recommended.**

**Option C — Swift shell + Python subprocess**: Two codebases, IPC complexity, process lifecycle management. The Vibe project (Tauri + Rust sidecar) validates this pattern works, but it doubles debugging surface area. Only justified if you need Python-specific ML libraries.

**Option D — Swift + WhisperKit**: The cleanest architecture. Single language, single codebase, SPM dependency management, no compilation of C++ code. WhisperKit's `try await WhisperKit()` followed by `pipe.transcribe(audioPath:)` is the simplest integration path. VoiceInk and Vocorize prove that Swift + Whisper dictation apps work in production.

**Option E — Electron/Tauri**: OpenWhispr (Electron) requires a Swift helper just for Globe key support. Tauri is lighter but still needs platform-specific Rust code for hotkeys and paste simulation. Neither achieves native feel for a menu bar utility.

**Swift + WhisperKit (Option D) wins decisively.** For a Python developer learning Swift: SwiftUI is declarative (similar mental model to React), Xcode provides excellent autocomplete, and AI coding assistants handle Swift exceptionally well. The learning investment pays off immediately in reliability — native APIs for hotkeys, audio, clipboard, and permissions just work without the friction of cross-language bridging.

## Global hotkeys, audio recording, and the macOS permission maze

Three macOS permissions are required, and the approach to global hotkeys determines which ones.

**Global keyboard shortcuts** have two viable implementations. **Carbon `RegisterEventHotKey`** is technically deprecated but still functional on macOS Sequoia, requires **no permissions at all**, and is used internally by the two best Swift hotkey libraries: **KeyboardShortcuts** (by sindresorhus) and **HotKey** (by soffes). Apple's own engineers have stated they will ship replacement APIs before removing Carbon. The alternative, **CGEvent tap**, intercepts all keyboard events system-wide and requires **Input Monitoring** permission, but offers more flexibility (key-up detection for push-to-talk). For a toggle-style shortcut (press once to start, press again to stop), KeyboardShortcuts is the pragmatic choice — it provides a SwiftUI shortcut recorder component, stores the user's preference in UserDefaults, and handles conflict detection automatically.

**Audio recording** should use **AVAudioEngine** with an input tap. The hardware microphone records at its native sample rate (typically 48 kHz), and you downsample to 16 kHz mono via `AVAudioConverter` before writing to a WAV file. For arbitrarily long recordings, stream audio chunks to disk via `AVAudioFile` rather than accumulating in memory. The app needs `NSMicrophoneUsageDescription` in Info.plist, which triggers a one-time system permission dialog.

**Clipboard and auto-paste** use `NSPasteboard.general` to write the transcription, then `CGEvent` to simulate Cmd+V in the frontmost app. This paste simulation requires **Accessibility** permission, which the user must manually grant in System Settings > Privacy & Security > Accessibility — there is no programmatic way to auto-grant it. A small delay (~50 ms) between clipboard write and paste simulation ensures reliability. This is the same approach used by Maccy, Paste, and every clipboard manager on macOS.

The permission onboarding flow should be: **Microphone → Accessibility** (and optionally Input Monitoring if using CGEvent tap). Show a first-run wizard explaining each permission with a direct link to the relevant System Settings pane.

## Menu bar UI, storage, and the recording state indicator

**SwiftUI's `MenuBarExtra`** (macOS 13+) with `.window` style provides a rich popover UI directly from the menu bar icon. The menu bar icon should toggle between `mic` and `mic.fill` (with a red tint or a composited red dot) to indicate recording state — this is reactive via `@Observable` state. Use the `.window` style to render a full SwiftUI view in the dropdown: recent dictations list, a settings button, and a quit button. The `Settings` scene type gives you a native preferences window accessible via Cmd+,.

For **dictation history storage**, SQLite via **GRDB.swift** (v7.5+) is the right tool. It's a single-file database in `~/Library/Application Support/YourApp/`, supports full-text search across transcriptions, and makes retention cleanup trivial: `DELETE FROM transcriptions ORDER BY date ASC LIMIT (SELECT COUNT(*) - :maxToKeep)`. Store transcription text, timestamp, duration, and optionally the audio file path. Audio files live alongside the database as individual WAV files. UserDefaults handles app preferences only (shortcut key, retention count, model selection, launch-at-login toggle).

**Launch at login** uses `SMAppService.mainApp.register()` (macOS 13+), wrapped cleanly by sindresorhus's LaunchAtLogin package which provides a SwiftUI toggle.

## Seven open-source projects to study before writing code

The landscape of existing macOS Whisper dictation tools reveals what works and what doesn't. These projects should be studied in order of relevance:

- **VoiceInk** (Swift + whisper.cpp, 3,700 stars, GPLv3) — The most successful open-source native dictation app. Features per-app settings ("Power Mode"), personal dictionary, AI enhancement via local LLMs. Best reference for overall architecture, menu bar UI patterns, and whisper.cpp integration in Swift.
- **OpenSuperWhisper** (Swift + whisper.cpp submodule, 620 stars, MIT) — Clean implementation of configurable global hotkeys including single-modifier keys, hold-to-record, and Homebrew distribution. Study this for hotkey and build system patterns.
- **Vocorize** (Swift + WhisperKit + TCA) — Validates the WhisperKit-based architecture with Swift Composable Architecture. Study for WhisperKit integration patterns.
- **SpeakType** (Swift + WhisperKit) — Minimal viable WhisperKit dictation app. Press fn to dictate. Good starting point to understand cold-start behavior and the simplest possible architecture.
- **WhisperKit** itself (5,669 stars) — The framework's sample app and documentation are excellent. TestFlight builds available. Study the async transcription API and streaming patterns.
- **superwhisper** (closed source, commercial) — The gold standard UX for dictation. Uses accessibility APIs for app context awareness, ⌥+Space hotkey, auto-paste, custom modes. Study its interaction patterns, not its code.
- **whisper-writer** (Python, 2,000 stars) — Reference for the hotkey → record → transcribe → type workflow. Study the state machine design even though the implementation is Python/Windows-focused.

Notable gaps across all existing tools: none provide a truly open-source, Swift-native, WhisperKit-based dictation app with configurable history retention and the large-v3-turbo model. This is the niche the proposed tool fills.

## Concrete build plan: from zero to daily-driver in two weeks

**Project structure:**

```
WhisperDictation/
├── WhisperDictation.xcodeproj
├── Package.swift                    # SPM dependencies
├── Sources/
│   ├── App/
│   │   ├── WhisperDictationApp.swift    # @main, MenuBarExtra, Settings scene
│   │   └── AppState.swift               # @Observable central state
│   ├── Recording/
│   │   ├── AudioRecorder.swift          # AVAudioEngine wrapper
│   │   └── AudioConverter.swift         # Resample to 16kHz mono WAV
│   ├── Transcription/
│   │   ├── TranscriptionEngine.swift    # WhisperKit wrapper, model management
│   │   └── TranscriptionResult.swift    # Data model
│   ├── Hotkey/
│   │   └── HotkeyManager.swift          # KeyboardShortcuts configuration
│   ├── Clipboard/
│   │   └── PasteManager.swift           # NSPasteboard + CGEvent paste
│   ├── Storage/
│   │   ├── Database.swift               # GRDB setup, migrations
│   │   └── DictationRecord.swift        # SQLite record type
│   └── Views/
│       ├── MenuBarView.swift            # Dropdown content
│       ├── HistoryListView.swift        # Recent dictations
│       └── SettingsView.swift           # Preferences
├── Resources/
│   └── Info.plist                       # Permissions descriptions
└── Tests/
```

**Dependencies (SPM):**
- `argmaxinc/WhisperKit` — transcription engine
- `sindresorhus/KeyboardShortcuts` — global hotkey with SwiftUI recorder
- `sindresorhus/LaunchAtLogin` — login item management
- `groue/GRDB.swift` — SQLite database

**Implementation order (each phase is a shippable milestone):**

**Phase 1 — Recording + transcription CLI (Days 1–3).** Get WhisperKit transcribing audio files on your M1. Create a simple Swift command-line tool that records N seconds of audio via AVAudioEngine, saves to WAV, and transcribes with WhisperKit. This validates the core ML pipeline and surfaces any model download, CoreML compilation, or audio format issues early. Test with dictation samples of varying lengths (30s, 2 min, 10 min).

**Phase 2 — Menu bar shell with hotkey (Days 4–6).** Build the SwiftUI MenuBarExtra app skeleton. Add KeyboardShortcuts for the toggle shortcut. Implement the state machine: Idle → Recording → Transcribing → Done. Show recording state via the menu bar icon. Wire the hotkey to start/stop AVAudioEngine recording. At this stage, transcription can be a placeholder — the focus is on the macOS integration layer working flawlessly.

**Phase 3 — Transcription integration + clipboard paste (Days 7–9).** Connect WhisperKit to the recording pipeline. On stop-recording, pass the audio file to WhisperKit, transcribe, copy result to NSPasteboard, simulate Cmd+V via CGEvent. Handle Accessibility permission. Add a loading indicator during transcription. Test across apps (Terminal, VS Code, Safari, Notes, Slack) to verify paste reliability.

**Phase 4 — History, settings, and polish (Days 10–14).** Add GRDB database for dictation history. Build the history list view in the dropdown. Implement configurable retention (keep last N dictations, auto-delete older ones including audio files). Build the Settings view: shortcut key customization, retention count, model selection, launch-at-login toggle. Add first-run permission onboarding. Handle edge cases: what if the user presses the hotkey during transcription? What if the model isn't downloaded yet?

**Testing strategy:** Manual testing across target apps is essential — fullscreen apps, Electron apps (Slack, VS Code), native apps (Notes, Safari), and terminal emulators. Test long dictation sessions (5+ minutes). Monitor memory usage during recording and transcription via Activity Monitor. Verify the app survives sleep/wake cycles and audio device changes (plugging in headphones mid-recording).

**Packaging:** For personal use, archive in Xcode → export as `.app` → place in `/Applications`. No App Store submission needed. Optionally create a DMG with `create-dmg` or distribute via Homebrew tap like OpenSuperWhisper. Code-sign with a free Apple Developer account to avoid Gatekeeper warnings.

## Conclusion

The optimal architecture is a **pure Swift app using WhisperKit, SwiftUI MenuBarExtra, KeyboardShortcuts, and GRDB** — four well-maintained SPM dependencies, zero Python, zero C++ bridging, zero subprocess management. WhisperKit's Neural Engine optimization matches or exceeds whisper.cpp performance on M1 while eliminating an entire class of build complexity. The **large-v3-turbo** model delivers near-large-v3 accuracy at 6× the speed in under 4 GB of memory. Carbon-based global hotkeys (via KeyboardShortcuts) require no special permissions, and `CGEvent` paste simulation is the same proven approach used by every clipboard manager on macOS. The entire project is four SPM dependencies, ~15 Swift files, and two weeks of focused work to a daily-driver dictation tool that runs entirely on-device.