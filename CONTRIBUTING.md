# Contributing to SimpleDisplay

Thank you for your interest in contributing!

## Prerequisites

- macOS 14.0+
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+

## Build Instructions

```bash
git clone https://github.com/SamuelRioTz/SimpleDisplay.git
cd SimpleDisplay
make run        # Debug build and launch
make run-release # Release build and launch
make dmg        # Build, sign, and create DMG
```

## Project Structure

```
Sources/
  SimpleDisplay/
    SimpleDisplayApp.swift          # App entry point (MenuBarExtra)
    Models/
      DisplayInfo.swift             # Display and DisplayMode models
    Services/
      DisplayService.swift          # Physical display management (CG APIs)
      VirtualDisplayService.swift   # Virtual display creation (private API)
    ViewModels/
      DisplayManagerViewModel.swift # Main app state
    Views/
      MenuBarContentView.swift      # Root menu bar popover
      DisplayRowView.swift          # Individual display row
      VirtualDisplayEditorView.swift # Create/edit virtual displays
      SettingsView.swift            # App settings
      DisplayConfigView.swift       # Device presets data
  VirtualDisplayBridge/
    VirtualDisplayWrapper.m         # ObjC bridge for CGVirtualDisplay
    include/
      VirtualDisplayBridge.h        # Bridge header
```

## Code Signing

SimpleDisplay uses ad-hoc signing for development:

```bash
make sign   # Ad-hoc codesign with hardened runtime
```

> **Note:** SimpleDisplay uses private Apple APIs (`CGVirtualDisplay`). It cannot be distributed via the Mac App Store.

## Guidelines

- Open an issue first for significant changes
- Keep PRs focused on a single change
- Match existing code style
- Test on both Apple Silicon and Intel if possible
- Don't add features beyond what was discussed in the issue

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
