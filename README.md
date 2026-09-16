# 🏔️ NotchCove

> A lightweight, blazing-fast macOS companion that turns your notch into a sheltered harbor for your active files and tools.

Built with a **Rust core engine** for high-performance file management and temporary staging, paired with a **Swift/SwiftUI native shell** for 120Hz ProMotion spring animations and frosted glass materials.

---

## ✨ Features (Phase 1: The Quick Drop Shelf)

- **Seamless Hardware Integration**:
  - Automatically detects the physical MacBook camera notch using `NSScreen.safeAreaInsets` and anchors flush to the bezel.
  - On external displays or non-notched Macs, automatically transitions to an elegant **floating pill**.
- **Quick Drop & Stash**:
  - Drag any file, folder, image, or document to the top of your screen to dock it into the Cove.
  - Haptic feedback confirmation upon docking.
- **Drag-Out Support**:
  - Drag stashed files straight out of the Cove into Finder, Slack, Mail, or web browsers.
- **Instant Actions**:
  - Right-click context menu: *Reveal in Finder*, *Open File*, *Copy File Path*, or *Remove*.
  - One-click *Clear All* to purge the shelf.
- **Microscopic Footprint**:
  - Entire app bundle is **< 900 KB**.
  - **0% CPU** at idle.
  - Statically linked Rust core (no runtime dependencies).
- **Background Menu Bar Companion**:
  - Lives unobtrusively in your menu bar (`tray.2` icon).
  - Shortcut: `Cmd + Shift + C` to toggle the shelf anytime.

---

## 🏗️ Architecture

```
NotchCove/
├── core/                         # [Rust Engine]
│   ├── src/lib.rs                # C-ABI export boundaries
│   ├── src/shelf.rs              # Staged file engine, mime detection, metadata
│   └── Cargo.toml                # Compiles into staticlib (libcove_core.a)
│
├── app/                          # [Swift / SwiftUI Shell]
│   ├── Sources/NotchCove/
│   │   ├── main.swift            # App entry point
│   │   ├── AppDelegate.swift     # Menu bar status item & app lifecycle
│   │   ├── NotchWindow.swift     # Non-activating floating panel & tracking
│   │   ├── NotchGeometry.swift   # Physical notch & virtual pill detection
│   │   ├── NotchCoveView.swift   # SwiftUI shelf UI, drag & drop, animations
│   │   └── RustBridge.swift      # Swift wrapper over Rust C-ABI
│   └── Sources/CCoveCore/        # C header & modulemap for Swift interop
│
├── scripts/
│   ├── build.sh                  # One-command compile (Rust + Swift -> .app)
│   └── run.sh                    # Build and launch NotchCove
└── build/                        # Output folder containing NotchCove.app
```

---

## 🚀 Getting Started

### Prerequisites
- macOS 14.0 (Sonoma) or newer
- Apple Command Line Tools (`swift` compiler)
- Rust toolchain (`cargo` / `rustup`)

### Build & Run
To compile both the Rust engine and Swift app, and assemble `NotchCove.app`:

```bash
# Build the application
./scripts/build.sh

# Run NotchCove
./scripts/run.sh
```

---

## 🗺️ Roadmap

- [x] **Phase 1**: Quick Drop File Shelf & Physical/Virtual Notch geometry
- [ ] **Phase 2**: Media Player HUD (Spotify / Apple Music now-playing controls with waveform visualizer)
- [ ] **Phase 3**: System glanceables (Volume & brightness pill HUD replacer, battery charging alert)
- [ ] **Phase 4**: AirDrop target integration & quick format conversion (PNG -> WebP, Zip stash)
