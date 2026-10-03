# Gijilog (ギジログ)

A macOS app that writes meeting minutes while your video call is still going.
Keep its compact window next to the call to see what has been decided, what is still open, and who owns each task.

[日本語](README.md)

> [!NOTE]
> The interface and the generated minutes are in Japanese.

<p>
  <img src="docs/images/compact.jpg" alt="Compact window during a meeting" height="420">
  <img src="docs/images/main.jpg" alt="Full window for reviewing a meeting" height="420">
</p>

## Features

- **Records any call**: captures the Mac's audio output and your microphone while you stay in Zoom, Teams, Google Meet, or any other app. Your meeting app's settings are left alone.
- **Live minutes**: transcribes about every 12 seconds with OpenAI and extends the minutes every 30 seconds.
- **Made for running the meeting**: the compact window lists decisions, open questions, and action items, highlights what the latest update changed, and flags actions that still lack an owner or a deadline.
- **Grounded in what was said**: every item links to the time of the utterances behind it. Items without supporting utterances, and owners or deadlines nobody said, are left out.
- **From existing recordings too**: import a Voice Memo, a Zoom recording, or any audio or video file and get the same minutes afterward.
- **Audio and minutes together**: each meeting gets a folder with `議事録.md` (minutes) and `録音.m4a` (audio).

## Requirements

- macOS 15 or later
- An OpenAI API key (you pay for your own usage)
- To build: Swift 6 or later (Xcode or the Command Line Tools) and [SwiftLint](https://github.com/realm/SwiftLint)

## Getting started

```sh
brew install swiftlint
git clone https://github.com/nutcase/gijilog.git
cd gijilog
./scripts/build.sh
open dist/ギジログ.app
```

1. Open Settings (⌘,) and save your OpenAI API key.
2. Click 録音を開始 (Start recording). The first time, macOS asks for Screen & System Audio Recording permission: turn on ギジログ in System Settings and reopen the app. Allow microphone access when asked.
3. Click 録音を開始 again to start recording and writing the minutes.

> [!NOTE]
> Builds are signed ad hoc by default, so every rebuild loses the recording permission. Clear the stale entry and repeat step 2:
>
> ```sh
> tccutil reset ScreenCapture io.github.nutcase.gijilog
> ```
>
> To keep the permission across rebuilds, create a self-signed code-signing certificate in Keychain Access (Certificate Assistant → Create a Certificate, identity type Self-Signed Root, certificate type Code Signing) and build with `GIJILOG_SIGN_IDENTITY="<certificate name>" ./scripts/build.sh`.

## Minutes from a recording file

Click ファイルから作成 (Create from file) or drop audio or video files on the window. Each file is cut into about 30-second pieces, transcribed, and then summarized into minutes. All audio tracks are mixed, and importing never blocks stopping a recording. The meeting takes the file's name and creation date, and its folder gets `議事録.md` and `録音.m4a`; the original file is left as is.

## Where meetings are saved

By default in `~/Documents/ギジログ`, one folder per meeting. You can choose another folder in Settings; existing meetings move with it.

```text
~/Documents/ギジログ/
└── 2026-10-03 17.26 Weekly sync/
    ├── 議事録.md        minutes and transcript, rewritten as the meeting changes
    ├── 録音.m4a         Mac audio and microphone mixed for listening back, written after recording stops
    ├── system.caf       the rest is the app's own data
    ├── microphone.caf
    ├── chunks/
    ├── recording.json
    └── meeting.json
```

## Privacy and consent

- **Sent to OpenAI**: about 12 seconds of audio at a time (silence is skipped), the transcript text, and the minutes so far. Minutes are requested with `store: false`.
- **Kept on your Mac**: recordings, transcripts, and minutes. The API key stays in the Keychain and is never written to meeting files.
- **Consent**: tell participants and get their consent before recording or transcribing a meeting, and follow the laws and policies that apply to you.
- **Review**: the minutes are an AI summary. Check anything important against the transcript.

If your Documents folder syncs with iCloud Drive, recordings are uploaded too.

## Limitations

- No speaker identification: "Mac音声" and "マイク" are where the sound came from, not who spoke.
- Playing the call through speakers records it twice through the microphone. Use headphones.
- 30 seconds is the update interval, not a guarantee; slow networks or APIs delay updates.
- Very long meetings send the growing minutes each time and can approach the model's input limit.
- No Developer ID signing or notarization yet: build from source.

## Development

```sh
./scripts/check.sh   # format check, SwiftLint, regression tests, release build
./scripts/format.sh  # format the Swift sources
./scripts/test.sh    # regression tests only
./scripts/build.sh   # build dist/ギジログ.app after the checks pass
```

The 39 regression tests cover chunking and the shared recording clock, incremental minutes and evidence checks, retries and recovery after restart, moving the save location and upgrading from earlier versions, mixing the audio, and importing recording files. Speech recognition and the API are mocked, and any unmocked network request fails. GitHub Actions runs SwiftLint, the tests, and a release build on every push and pull request.

With only the Command Line Tools installed, SwiftUI's `@State` does not compile, so view state lives in `ObservableObject`s.

## Contributing

Issues and pull requests are welcome. Run `./scripts/check.sh` before opening a pull request. Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.

## License

[MIT](LICENSE)
