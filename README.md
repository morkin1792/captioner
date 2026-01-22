# Captioner

A cross-platform video captioning app that automatically generates and translates video captions using AI.

<div align="center">
  <img src="https://github.com/user-attachments/assets/a5b6db1e-81c0-475b-9077-06010321a55e" alt="drawing" width="250">
</div>

## Features

- **Automatic Transcription**: Uses AssemblyAI to transcribe video audio
- **Multi-language Translation**: Translates captions to multiple languages using Gemini AI
- **Customizable Styling**: Choose font, size, and caption position
- **Live Preview**: See how captions look before processing
- **Cross-platform**: Works on Linux, Windows, macOS, and Android

<p align="center">
  <img src="https://github.com/user-attachments/assets/627e2cde-9131-4740-86bb-b62257bb1214" alt="drawing" width="900">
</p>


## Prerequisites

### Linux / macOS / Windows
- **FFmpeg**: Must be installed system-wide
  ```bash
  # Ubuntu/Debian
  sudo apt install ffmpeg
  
  # Arch Linux
  sudo pacman -S ffmpeg

  # macOS
  brew install ffmpeg

  # Windows (you may need to reopen the app after the command below)
  winget install ffmpeg
  ```

### Android
- FFmpeg is bundled with the app automatically

## Installation

### A) Pre-built Releases

Download the latest release for your platform from the [Releases page](../../releases).


### B) From Source

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd captioner
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run or build the app:
   ```bash
   # Linux
   flutter run -d linux
   flutter build linux --release
   
   # Windows
   flutter run -d windows
   flutter build windows --release

   # macOS
   flutter run -d macos
   flutter build macos --release

   # Android (with device connected)
   flutter run -d android
   flutter build apk --release
   ```

## API Keys Required

This app requires API keys from:

1. **AssemblyAI** (Required) - For speech-to-text transcription
   - Sign up and get your key at: https://www.assemblyai.com/

2. **Gemini API** (Recommended, but optional) - For translation
   - Get your key at: https://aistudio.google.com/apikey
   - If not provided, the translation feature will be disabled.
   
   > ⚠️ **Important**: Avoid using a **Free tier** project, as the rate limits are very restrictive and will cause frequent translation errors. It is better creating a project with **Free Trial credits** (comes with $300) or using a **Paid** billing account for reliable performance.

The app will prompt you to enter these keys on first launch. Keys are stored securely in your system keyring (Linux), Windows Credential Manager (Windows), macOS Keychain (macOS), or Android Keystore (Android).

## Usage

1. **Setup**: Enter your API keys
2. **Select Video**: Choose a video file from your device
3. **Set Original Language**: Select the language spoken in the video
4. **Choose Caption Languages**: Select which languages you want captions in
5. **Customize Style**: Adjust font, size, and position
6. **Process**: Let the app transcribe, translate, and render your video
7. **Save**: Export the video with embedded captions

## Supported Languages

**Transcription** (via AssemblyAI):
- English, Portuguese, Spanish, and many more

**Translation** (via Gemini):
- Any language supported by Gemini AI
