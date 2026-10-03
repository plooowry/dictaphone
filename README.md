# Dictaphone

A tiny macOS menu-bar dictation app. Press **⌘D** anywhere to record, press it again to stop —
your speech is transcribed on-device, copied to the clipboard, and saved. It can read transcripts
back to you with macOS voices or natural-sounding on-device neural voices (Kokoro).

Everything runs locally. No account, no cloud, no API keys.

## Download

1. Grab **Dictaphone-macOS.zip** from the [Releases](../../releases) page and unzip it.
2. Drag **Dictaphone.app** into your Applications folder.
3. The app isn't notarized, so the first time **right-click → Open** (or run
   `xattr -cr /Applications/Dictaphone.app`), then allow microphone access.

Requires an Apple Silicon Mac running macOS 14 or later. The first launch downloads the Whisper
`base.en` speech model (~150 MB); the first use of a neural voice downloads ~350 MB.

## Use

| Shortcut | Action |
|---|---|
| ⌘D | Start / stop recording and transcribe |
| ⌥⌘D | Read the latest transcript aloud (press again to stop) |

The window shows each transcript as a card with play, copy and delete buttons. Choose a voice
(macOS or Kokoro neural), set the speed, turn on auto-read, or "Read all". Transcripts are saved in
`~/Library/Application Support/Dictaphone/`.

Note: ⌘D is registered globally, so it overrides "Bookmark" shortcuts in other apps while Dictaphone runs.
Edit the key in `registerHotKeys()` if you prefer another.

## Build from source

Needs Xcode (Swift 5.9+).

```bash
./build.sh          # builds Dictaphone.app and dist/Dictaphone-macOS.zip
open Dictaphone.app
```

## Built with

[WhisperKit](https://github.com/argmaxinc/WhisperKit) (speech-to-text) and
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Kokoro text-to-speech).
