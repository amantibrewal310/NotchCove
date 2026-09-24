# 🏔️ NotchCove

> A lightweight, blazing-fast macOS companion that turns your notch into a sheltered harbor for your active files and tools.

Built with a **Rust core engine** for high-performance file management and temporary staging, paired with a **Swift/SwiftUI native shell** for 120Hz ProMotion spring animations and frosted glass materials.

---

## ✨ Features (Phase 1: The Drop Bar Shelf)

- **Lives in the notch**
  - Sits flush with the MacBook camera notch (`NSScreen.safeAreaInsets`). On external or non-notched displays it draws a virtual notch inside the menu bar, so it never covers your windows.
  - Hover the notch to peek, click it to keep it open until you click elsewhere, or press **⌃⌥C** from anywhere.
- **Drag in, like Dropzone's Drop Bar**
  - The shelf opens with a drop zone as soon as you start dragging files, so you never have to push into the top edge (which triggers Mission Control). Release anywhere else and it closes itself. Prefer the quieter behaviour? *Open Shelf While Dragging → Only Near the Notch*.
  - Only real drag sessions trigger it. Moving windows or selecting text near the top of the screen does not.
  - Files dropped together stay together as a **stack**. Double-click a stack to open it, or right-click and choose *Split Stack*.
  - Accepts more than files: **promised files** (Mail, Photos, Safari), **images** from browsers, **links** (saved as `.webloc`), and **text** (saved as `.txt`). ⌘V pastes the clipboard onto the shelf.
- **Drag out**
  - Drag a file, a stack, a multi-selection, or everything at once (the stack icon in the header) into Finder, Slack, Mail, or a browser upload.
  - Originals are **copied** by default and never moved by accident. Hold **⌘** while dragging to move them instead.
  - The shelf moves out of the way while you drag, so you can drop onto whatever is underneath.
  - Dropped items leave the shelf. Turn on *Keep Items After Dragging Out* in the menu bar to keep them.
- **Quick actions** (right-click, or with the keyboard while the shelf is focused)
  - Quick Look (Space), Open (⏎), Open With, Reveal in Finder (⌘R), Share, AirDrop, Compress to zip, Copy (⌘C), Copy Path, Remove (⌫).
  - Select with click, ⌘-click, ⇧-click, ⌘A, or ← →. Esc closes.
- **Persistent**: the shelf survives restarts. Entries whose files have been deleted are pruned. Files NotchCove creates itself (snippets, links, archives, received images) live in `~/Library/Application Support/NotchCove/Inbox` and are cleaned up when you remove them. Your own files are never deleted.
- **Auto-clear**: items leave the shelf after **12 hours** by default (choose 1 hour, 1 day, 7 days or never). Your files stay where they are; only NotchCove's own inbox files (snippets, links, archives, received images) are deleted. No polling: one timer is armed for the next expiry, plus a check at launch and on wake.
- **Screenshots to the shelf** (off by default): new screenshots appear on the shelf, which pops open for a moment. Choose *Add to Shelf, Keep Saved File* (the screenshot is still saved where macOS puts it) or *Move to Shelf Only* (keeps the Desktop clean; the file lives in the Cove Inbox and is cleared with the shelf unless you drag it out). Watches only the screenshot folder, with no polling. Tip: turn off *Show Floating Thumbnail* in the ⌘⇧5 options so screenshots are saved, and reach the shelf, instantly.
- **Full-screen friendly**: in full-screen apps the notch drops the item count beside it, so nothing sticks out of the black top strip. Hover, click, drag and ⌃⌥C still open the shelf.
- **Item count beside the notch** while it's closed; turn off *Show Item Count Beside Notch* for a plain black notch.
- **Removing items** plays a small poof over the card, like Dropzone.
- **Launch at Login** from the menu bar icon.
- **Themes**: *Lantern* (warm amber, the default), *Graphite* (system blue) or *Signal* (vivid pink). The shelf stays black in all three.
- **Settings** (menu bar icon): *Open Shelf While Dragging*, *Theme*, *Shelf Size* (Compact / Regular / Large), *Auto-Clear Items*, *Screenshots*, *Show Item Count Beside Notch*, *Keep Items After Dragging Out*, *Launch at Login*, *Open Cove Inbox Folder*.
  To preview the external-display look on a MacBook: `defaults write com.notchcove.app ForceVirtualNotch -bool YES`.
- **Lightweight**: ~0% CPU at idle and while the pointer moves, ~0.4% during mouse drags, 16–30 MB of memory, and a ~800 KB app bundle.
  Hover uses a tracking area on the notch window, not a system-wide move monitor, and drags are sampled only while the button is down.
- **No permissions needed**: no Accessibility or Screen Recording prompts. Mouse monitoring and the Carbon hotkey work without them.

---

## 🏗️ Architecture

```
NotchCove/
├── core/                         # [Rust Engine]
│   ├── src/lib.rs                # C-ABI export boundaries
│   ├── src/shelf.rs              # Shelf model: stacks, persistence, inbox ownership
│   ├── src/actions.rs            # File actions (zip via ditto)
│   └── Cargo.toml                # Compiles into staticlib (libcove_core.a)
│
├── app/                          # [Swift / SwiftUI Shell]
│   ├── Sources/NotchCove/
│   │   ├── main.swift            # App entry point
│   │   ├── AppDelegate.swift     # Menu bar status item & app lifecycle
│   │   ├── NotchWindow.swift     # Panel, drop destination, open/close state machine
│   │   ├── NotchGeometry.swift   # Physical & virtual notch geometry
│   │   ├── ShelfView.swift       # SwiftUI shelf UI & animations
│   │   ├── DropIngest.swift      # Files, promises, images, links, text → shelf
│   │   ├── DragOut.swift         # Drag source, card mouse handling
│   │   ├── ItemActions.swift     # Quick Look & context-menu actions
│   │   ├── Thumbnails.swift      # Quick Look thumbnails
│   │   ├── HotKey.swift          # Global ⌃⌥C shortcut (Carbon)
│   │   └── RustBridge.swift      # Swift wrapper over Rust C-ABI
│   └── Sources/CCoveCore/        # C header & modulemap for Swift interop
│
├── scripts/
│   ├── build.sh                  # One-command compile (Rust + Swift -> .app)
│   └── run.sh                    # Build and launch NotchCove
└── build/                        # Output folder containing NotchCove.app
```

---

## 📥 Install

Apple Silicon Macs, macOS 14 (Sonoma) or newer:

```bash
brew install --cask amantibrewal310/tap/notchcove
```

Update with `brew upgrade --cask notchcove`; remove with `brew uninstall --cask notchcove` (add `--zap` to also delete the shelf's data).

---

## 🚀 Getting Started

### Prerequisites
- macOS 14.0 (Sonoma) or newer
- Apple Command Line Tools (`swift` compiler)
- Rust toolchain: `brew install rustup && rustup default stable` (the build script also finds Homebrew's keg-only `rustup`)

### Build & Run
To compile both the Rust engine and Swift app, and assemble `NotchCove.app`:

```bash
# Build the application
./scripts/build.sh

# Run NotchCove
./scripts/run.sh

# Rust core tests
(cd core && cargo test)
```

### Releasing
Bump `VERSION`, commit and push, then run `./scripts/release.sh`. It tags the version, uploads `dist/NotchCove-<version>.zip` to a GitHub release, and updates the cask in [amantibrewal310/homebrew-tap](https://github.com/amantibrewal310/homebrew-tap). `./scripts/package.sh` builds the zip alone.

---

## 🗺️ Roadmap

- [x] **Phase 1**: Drop Bar shelf (stacks, drag in/out, promises, quick actions, persistence) & physical/virtual notch geometry
- [ ] **Phase 2**: Media Player HUD (Spotify / Apple Music now-playing controls with waveform visualizer)
- [ ] **Phase 3**: System glanceables (Volume & brightness pill HUD replacer, battery charging alert)
- [ ] **Phase 4**: AirDrop target integration & quick format conversion (PNG -> WebP, Zip stash)
