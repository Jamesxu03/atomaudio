# Audio Input

A free, fully local English dictation tool for macOS: hold a key, speak, release, and the text is typed into the app you're using.

**Status:** Phase 2+, a working menu-bar app. Speech goes through Parakeet TDT 0.6B v2 (chosen in Phase 1), your word list, and an on-device AI review before it's typed.

## Use the app

```sh
Scripts/build_app.sh --open        # builds and launches build/Audio Input.app
swift run -c release CoreChecks    # regression checks for the text rules (no Xcode needed)
```

1. A coral ring of dots appears in the menu bar. The first launch after a build takes about 12 s to load the models; the dots stay faint until it's ready.
2. Allow **Microphone**, and turn on **Audio Input** under **System Settings → Privacy & Security → Accessibility**. The menu has shortcuts to both settings.
3. Click into any text field, **hold Right ⌥**, speak, and **release**. The text is typed for you.

### What happens after you release

| Step | What it does | Time |
|---|---|---|
| Parakeet v2 | Turns speech into text on the Neural Engine | ~0.05 s |
| Cleanup rules | "Q\<unk\>A" → Q&A, removes um/uh, "I P O" → IPO, "DD slash NDA" → DD/NDA, your aliases ("you eye" → UI), term spelling (github → GitHub) | instant |
| AI review | Apple's on-device model fixes punctuation, misheard words and acronyms ("friend terms" → FRAND), using your word list. Its reply is **discarded** if it changed too much, so a dictated question is never answered | ~0.5 s |

Results by test set (word error rate):

| Test set | Plain Parakeet | App pipeline |
|---|---|---|
| Your 21 recordings | 7.6% | **7.3%** (and 13.1% → 9.1% counting punctuation) |
| 14 IP-scouting sentences, spoken letters | 8.1% | **1.5%** |
| The same, quiet and noisy | 4.4% | **3.0%** |

Everything runs offline; the AI review needs Apple Intelligence turned on.

**Word list:** use **Edit Word List…** in the menu, which opens `~/Library/Application Support/Audio Input/vocabulary.txt`. It ships with about 70 IP-scouting terms: DD, NDA, CDA, MTA, LOI, POC, FTO, PCT, TRL, USPTO, FRAND, CVC, R&D and more. Put one term per line, and optionally list what it gets misheard as: `UI: you eye`. Changes apply to the next dictation. Leave out terms that are everyday words (SAFE, SAM), because they'd be capitalized everywhere.

**Acoustic boosting is off.** FluidAudio can also listen for word-list terms directly in the audio (`boostWordList`, using a 100 MB CTC model). With this many short acronyms it replaced ordinary words: "team" → TAM, "slash" → SaaS. That raised the error rate on your recordings from 7.3% to 9.3%. To compare, run Bench with the `pipeline` engine (boosting on) and `pipeline-no-boost` (what the app uses).

### On-screen overlay

A pill at the bottom-center of the screen shows what's happening. It follows light/dark mode.
- **While you hold the key:** a coral ring of dots that swells with your voice, and a meter of dots that stretch into bars as you speak. The meter is tuned for quiet speech; if it stays flat, the mic isn't hearing you.
- **After you release:** the ring spins with "Transcribing…", then "Reviewing…".
- **Short notices:** for example "Didn't catch that". The pill never takes focus or blocks clicks.

To check the design without a mic: `.build/release/AudioInput --render-overlay-previews <dir>` renders the overlay states and menu-bar icons to PNG. `--render-app-iconset <dir>` renders the app icon; `App/AppIcon.icns` was made from it with `iconutil -c icns`.

### Other behavior
- Holds under 0.3 s are ignored.
- Pressing another key while holding Right ⌥ (for example ⌥E) cancels the recording, so Option shortcuts still work.
- Your clipboard is restored after each paste, and dictated text is marked so clipboard managers skip it.
- **Noise Suppression** in the menu turns on Apple's voice processing. It's off by default. If it can't start on your audio setup, the app records without it and says so.
- **Review with On-Device AI** can be turned off in the menu for the fastest, rules-only output.
- The log records only timings, never what you said: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "local.audioinput"'`

**After every rebuild, macOS asks for the permissions again.** The app is signed "ad-hoc", so each build looks like a new app to macOS. The build script clears the old grants for you. To avoid re-granting, sign with a real certificate: `SIGN_IDENTITY="Apple Development: …" Scripts/build_app.sh`. You can get one for free with an Apple ID in Xcode.

## Phase 0: record your voice

```sh
cd "/Users/internjames/Desktop/Audio Input"
swift run -c release RecordClips
```

- Edit `prompts.txt` first. Add the names, products and jargon you actually dictate, because that's where the engines differ most.
- The first time you run it, macOS asks to give your terminal app (VS Code or Terminal) microphone access.
- For each sentence: press Enter, read it, press Enter again. Type `q` to stop. Running it again picks up where you left off.
- Clips are saved to `TestClips/mine/` as 16 kHz WAV files, each with a `.txt` file holding the sentence. They're git-ignored and never leave your Mac.

## Phase 1: compare the engines

```sh
swift run -c release Bench                      # all four engines on TestClips/mine
swift run -c release Bench --engines parakeet-v2,apple-speech
swift run -c release Bench --clips TestClips/synthetic
```

| Engine | What it is |
|---|---|
| `parakeet-v2` | NVIDIA Parakeet TDT 0.6B v2, English-only, run through FluidAudio on the Neural Engine. **Current pick.** |
| `parakeet-v3` | The multilingual version of the same model |
| `parakeet-phonon2` | Retrained English-only version of v3 (optional, extra download) |
| `parakeet-ultra` | Retrained multilingual version of v3 (optional, extra download) |
| `pipeline-no-boost` | **Exactly what the app types:** Parakeet v2 + cleanup rules + on-device AI review |
| `pipeline` | The above plus acoustic word-list boosting (off in the app; see "Acoustic boosting is off") |
| `pipeline-no-ai` | Parakeet v2 + boosting + cleanup rules, without the AI review |
| `apple-speech` | macOS 26 `SpeechTranscriber`, built in |
| `apple-dictation` | macOS 26 `DictationTranscriber`, the system dictation model |

The tool prints a summary table and writes every mistake ("said" next to "heard") to `BenchResults/`.

- **WER (words)** is the word error rate, ignoring capitals, punctuation and number formatting ("ten" counts the same as "10").
- **WER (with case + punctuation)** is closer to what would actually be pasted.
- **Latency** is the compute time per clip, after the model has warmed up.

## Smoke test: synthetic voice, 2026-10-05

`Scripts/make_synthetic_clips.sh` reads `prompts.txt` aloud with macOS's built-in `say` voice (Samantha), producing 21 clips with 301 words. That checks the pipeline end to end. It's much easier than real speech, so **don't choose an engine from these numbers**; record your own voice first.

| Engine | WER (words) | WER (case + punctuation) | Avg latency | Speed vs real time |
|---|---|---|---|---|
| parakeet-v2 | 1.0% | 3.4% | 0.05 s | 97× |
| parakeet-v3 | 3.6% | 5.4% | 0.05 s | 96× |
| apple-speech | 5.0% | 9.1% | 0.11 s | 43× |
| apple-dictation | 5.0% | 14.5% | 0.16 s | 28× |

Apple's engines struggled with technical terms: "Kubernetes" became "R. Q. Bernitz", "pull request" became "pool request", and "cache" became "cash". Parakeet v2's only mishearing was "in VS Code" → "and VS Code".

## Your voice, quiet speech, MacBook Air built-in mic: 2026-10-05

21 clips recorded at a very low speaking volume. Peaks reached −21 dBFS and speech was only about 20 dB above the room noise. The input level setting was 48 out of 100.

| Engine | WER (words) | WER (case + punctuation) |
|---|---|---|
| parakeet-v2 | **7.6%** | 13.1% |
| parakeet-v3 | 8.9% | 13.8% |
| parakeet-ultra | 9.6% | 12.5% |
| parakeet-phonon2 | 16.2% | 19.5% |
| apple-speech | 20.9% | 26.3% |
| apple-dictation | 22.8% | 30.6% |

Raising the volume of the same clips to a normal level (+20 dB) didn't help Parakeet (9.3%), so loudness alone isn't the problem. To try Apple's noise suppression and automatic gain, record a second set:

```sh
swift run -c release RecordClips --voice-processing     # saves to TestClips/mine-vp
swift run -c release Bench --clips TestClips/mine-vp
```

## Privacy

- Parakeet models are downloaded once from Hugging Face to `~/Library/Application Support/FluidAudio/Models/`: about 450 MB for v2, plus about 100 MB for the word-list boosting model (`parakeet-ctc-110m`).
- The AI review uses Apple Intelligence's built-in on-device model; nothing is sent to Apple.
- Apple's speech model is installed and managed by macOS.
- After that, everything runs offline. No audio or text leaves the Mac.

## Requirements

- macOS 26 on Apple Silicon.
- Command Line Tools are enough for Phases 0–1.
- Command Line Tools are also enough to build the app (`Scripts/build_app.sh`). Full Xcode is only needed for free Apple ID signing.
