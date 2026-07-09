<p align="center">
  <img src="docs/screenshots/popover.png" width="460" alt="OnlyEQ menu bar popover">
</p>

# OnlyEQ

System-wide parametric EQ for macOS. Lives in the menu bar. No virtual audio drivers.

Every Mac EQ I tried either made me install BlackHole or a HAL driver, charged for parametric bands, or buried a simple job under a complicated UI. OnlyEQ instead uses the process tap API Apple added in macOS 14.4: it taps the system output mix, runs it through biquad filters, and plays the result back to your output device. Nothing to install, no password, no coreaudiod restarts, and your volume keys keep working. Adds about 10 ms of latency at the default 256-frame buffer (configurable from 128 to 1024 in Settings — this is fine for music and video; for latency-critical monitoring in a DAW, add the DAW to the exclude list instead).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/zollans/OnlyEQ/main/scripts/install.sh | bash
```

The app isn't notarized (there's no paid developer account behind this), so the script clears the quarantine flag after downloading — [read it first](scripts/install.sh) if that concerns you. Or build from source, it takes about a minute and only needs the Xcode Command Line Tools:

```sh
git clone https://github.com/zollans/OnlyEQ && cd OnlyEQ
./scripts/build-app.sh && cp -R build/OnlyEQ.app /Applications/
```

Requires macOS 14.4 or newer. On first launch it asks for System Audio Recording permission — that's the tap. macOS shows the purple recording indicator while EQ is active; audio never leaves your machine.

Starting with 1.1.0, OnlyEQ checks for signed updates automatically and installs them in the background. Right-click the menu-bar icon and choose **Check for Updates…** to check immediately. Versions 1.0.x need one final manual install of 1.1.0 before automatic updates are available.

## What it does

<p align="center">
  <img src="docs/screenshots/editor.png" width="760" alt="OnlyEQ parametric editor">
</p>

- Parametric EQ with a draggable curve editor. Peak, shelves, high/low pass, notch, band pass — as many bands as you want.
- Imports every headphone EQ format I could find: AutoEq, Equalizer APO, peqdb, Wavelet/GraphicEQ, Poweramp, OPRA, Peace, REW, eqMac. Drop a file, paste text, or search the peqdb and AutoEq databases from inside the app.
- Per-device profiles. Your headphone preset kicks in when the headphones connect; your speakers keep theirs.
- Volume boost up to 200%, automatic preamp so boosted EQ doesn't clip, a limiter as a safety net, A/B compare, one-click bypass.
- An exclude list for apps that handle their own audio (DAWs, Zoom).
- Global hotkeys for toggling EQ and cycling output devices. Launch at login. That's it — one popover, one editor window, one settings window.
- Signed automatic updates powered by [Sparkle](https://sparkle-project.org/).

<p align="center">
  <img src="docs/screenshots/import.png" width="620" alt="OnlyEQ import sheet">
</p>

## How it works

A muted global process tap silences the original system output; the tap and the real output device get wrapped in a private aggregate device; an IO callback reads the tapped audio, runs it through RBJ cookbook biquads (plus preamp and a stereo-linked limiter), and writes it to the device. Filter changes swap in atomically without touching the audio thread.

This is the same approach the newer generation of Mac audio tools moved to after macOS 14.4, and it kills the classic virtual-driver failure modes: Bluetooth devices distorting until reconnect, sample-rate mismatches, apps escaping the EQ because they pin their output device, and the driver breaking on every macOS update.

Trade-offs, honestly: the purple recording dot is always on while EQ runs, macOS below 14.4 isn't supported, and pro-audio apps doing their own low-level routing can misbehave with taps — that's what the exclude list is for.

## Development

Plain SwiftPM with no Xcode project. Sparkle is the sole package dependency:

```sh
swift run OnlyEQ --test               # self-test suite (importer + DSP)
swift run OnlyEQ --engine-probe       # headless engine check, prints JSON
swift run OnlyEQ --editor-probe       # 15-second editor UI profiling run
swift run OnlyEQ --screenshots out/   # renders the README screenshots
./scripts/build-app.sh release        # universal binary release build
./scripts/prepare-release.sh 1.1.2    # signed archive + appcast
```

Tests run inside the binary because the Command Line Tools don't ship XCTest. Diagnostics land in `~/Library/Logs/OnlyEQ.log`.

## Credits

OnlyEQ stands on a lot of other people's work, and it's only fair to say what came from where:

- [SoundMax](https://github.com/snap-sites/SoundMax) (and the [SoundMaxx](https://github.com/brimell/SoundMaxx) fork) was the direct inspiration — a native menu bar EQ for the Mac. OnlyEQ started as "that, but without the BlackHole dependency."
- The feature set borrows liberally from the apps that got these things right first: [eqMac](https://eqmac.app) (in-app AutoEq browsing), [SoundSource](https://rogueamoeba.com/soundsource/) (quick device switching, per-device behavior), and [FineTune](https://github.com/ronitsingh10/FineTune) (the per-app exclude list as the escape hatch for DAWs).
- Headphone correction data comes from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen and from [peqdb.com](https://peqdb.com) — the in-app browser fetches straight from both. The presets themselves build on measurements by oratory1990 and the many reviewers whose data those databases aggregate. None of that data is mine; it belongs to those projects and people.
- The filter math is Robert Bristow-Johnson's [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/), used by basically every parametric EQ in existence.
- The capture approach uses Apple's Core Audio process tap API; [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo was the best public documentation of how it fits together.
- Import formats were reverse-engineered from public exports and docs of [Equalizer APO](https://sourceforge.net/projects/equalizerapo/), [Wavelet](https://pittvandewitt.github.io/Wavelet/), Poweramp, [Peace](https://sourceforge.net/projects/peace-equalizer-apo-extension/), [REW](https://www.roomeqwizard.com), the [OPRA project](https://github.com/opra-project/OPRA), and eqMac.

## License

Public domain, under [The Unlicense](LICENSE). Do whatever you want with it — no attribution required.
