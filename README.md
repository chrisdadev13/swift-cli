# Audio Capture CLI

A simple command-line tool for capturing system audio on macOS using ScreenCaptureKit.

## Requirements

- macOS 12.3 or later (Monterey)
- Swift 5.8 or later

## Features

- Capture system audio
- Save audio to WAV file
- Configurable recording duration
- Verbose output option for monitoring audio batches

## Installation

1. Clone this repository
2. Build the project:

```bash
swift build -c release
```

3. The executable will be located at `.build/release/audio-cli`

## Usage

```bash
# Basic usage (records for 10 seconds by default)
.build/release/audio-cli

# Record for a specific duration (in seconds)
.build/release/audio-cli --duration 30

# Specify output file path
.build/release/audio-cli --output recording.wav

# Show verbose output (prints information about each audio batch)
.build/release/audio-cli --verbose

# Record indefinitely until interrupted (Ctrl+C)
.build/release/audio-cli --duration 0
```

### Command-line Options

- `-d, --duration <seconds>`: Duration in seconds to record (default: 10, use 0 for indefinite)
- `-o, --output <path>`: Output file path (default: output.wav)
- `-v, --verbose`: Show verbose output about audio batches
- `-h, --help`: Show help information
- `--version`: Show the version

## Permissions

This application requires screen recording permissions to capture system audio. When you first run the application, macOS will prompt you to grant these permissions in System Preferences.

## How It Works

The application uses Apple's ScreenCaptureKit framework to capture system audio. It:

1. Creates a capture stream configured for audio
2. Processes audio sample buffers as they arrive
3. Converts them to the appropriate format
4. Writes them to a WAV file

## Troubleshooting

If you encounter permission issues:

1. Go to System Preferences > Security & Privacy > Privacy > Screen Recording
2. Ensure the Terminal (or your IDE's terminal) has permission to record the screen
