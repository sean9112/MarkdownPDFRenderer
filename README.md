# MarkdownPDFRenderer

`MarkdownPDFRenderer` is a macOS SwiftUI app for importing Markdown, rendering Markdown / LaTeX / Mermaid with a styled HTML template, and exporting the result as PDF.

## Features

- Import a single `.md` file
- Import a folder and automatically locate the Markdown entry file
- Import a `.zip` archive and resolve local assets after extraction
- Render Markdown, LaTeX, and Mermaid in a preview
- Export PDF in the app's styled theme
- Resolve relative links to local images and supported files beside the Markdown document

## Design

The app theme follows the provided palette:

- Primary text: `#141413`
- Primary background: `#FAF9F5`
- Secondary gray: `#B0AEA5`
- Section background: `#E8E6DC`
- Accent orange: `#D97757`
- Accent blue: `#6A9BCC`
- Accent green: `#788C5D`

## Project Structure

- `Sources/MarkdownPDFRendererApp/`
  Main app source, renderer HTML, and asset catalog.
- `MarkdownPDFRenderer.xcodeproj`
  Primary Xcode project for building the macOS app.
- `Scripts/package_app.sh`
  Builds the Xcode target and copies the app bundle into `dist/`.
- `IconComposer/AppIcon.icon`
  Original Icon Composer source retained for future icon editing.
- `Package.swift`
  Swift Package manifest kept for source organization compatibility.

## Requirements

- macOS 13 or later
- Xcode installed at `/Applications/Xcode.app`

## Build

Build and package the app from Terminal:

```bash
./Scripts/package_app.sh
```

Output app bundle:

```bash
dist/MarkdownPDFRenderer.app
```

Open in Xcode:

```bash
open MarkdownPDFRenderer.xcodeproj
```

## Notes

- The current renderer setup depends on the JavaScript libraries referenced by the bundled HTML renderer. If those libraries are loaded from CDN, exporting requires network access at runtime.
- The repository keeps both the Xcode project and the original Icon Composer source so the app icon can be iterated later.

## License

This project is licensed under the MIT License. See [LICENSE](/Users/sean9112/MarkdownPDFRenderer/LICENSE).
