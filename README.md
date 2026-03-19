# MarkdownPDFRenderer

macOS SwiftUI app for importing Markdown, rendering Markdown / LaTeX / Mermaid, and exporting PDF.

## Main Structure

- `Sources/MarkdownPDFRendererApp/`
  Single source of truth for the app code, renderer HTML, and asset catalog.
- `MarkdownPDFRenderer.xcodeproj`
  Main Xcode project for building the `.app`.
- `Scripts/package_app.sh`
  Builds the Xcode target and copies the app into `dist/`.
- `IconComposer/AppIcon.icon`
  Original Icon Composer source file kept for future icon edits.

## Build

From Terminal:

```bash
./Scripts/package_app.sh
```

Built app output:

```bash
dist/MarkdownPDFRenderer.app
```

If you want to work in Xcode directly, open:

```bash
MarkdownPDFRenderer.xcodeproj
```
