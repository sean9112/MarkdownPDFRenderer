import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private extension Bundle {
    static var rendererBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    func rendererHTMLURL() -> URL? {
        if let direct = url(forResource: "renderer", withExtension: "html") {
            return direct
        }

        return url(forResource: "renderer", withExtension: "html", subdirectory: "Resources")
    }
}

private enum Palette {
    static let text = Color(hex: 0x141413)
    static let background = Color(hex: 0xFAF9F5)
    static let muted = Color(hex: 0xB0AEA5)
    static let soft = Color(hex: 0xE8E6DC)
    static let accent = Color(hex: 0xD97757)
    static let accentBlue = Color(hex: 0x6A9BCC)
    static let accentGreen = Color(hex: 0x788C5D)
    static let uiText = Color(hex: 0x322F29)
    static let uiTextBright = Color(hex: 0x444036)
    static let uiMutedText = Color(hex: 0x787062)
    static let uiSuccessText = Color(hex: 0x6F8E4B)
    static let uiErrorText = Color(hex: 0xE08A6F)
}

@MainActor
final class PreviewStore: ObservableObject {
    private var currentMarkdown = ""
    private var currentBaseDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private var currentSourceRootURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    func updateSource(markdown: String, baseDirectoryURL: URL, sourceRootURL: URL) {
        currentMarkdown = markdown
        currentBaseDirectoryURL = baseDirectoryURL
        currentSourceRootURL = sourceRootURL
    }

    func exportPDF(to url: URL) async throws {
        let exporter = try OffscreenPDFExporter(
            markdown: currentMarkdown,
            baseDirectoryURL: currentBaseDirectoryURL,
            sourceRootURL: currentSourceRootURL
        )
        let data = try await exporter.export()
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }
}

private struct RenderRequest: Equatable {
    let id: UUID
    let markdown: String
    let baseDirectoryURL: URL
    let sourceRootURL: URL
}

private struct ExportMetrics {
    let width: CGFloat
    let height: CGFloat
    let viewportHeight: CGFloat
}

private struct ImportedMarkdownDocument {
    let markdownURL: URL
    let markdownText: String
    let baseDirectoryURL: URL
    let sourceRootURL: URL
    let extractedRootURL: URL?
}

@MainActor
private final class OffscreenPDFExporter: NSObject, WKNavigationDelegate {
    private let markdown: String
    private let baseDirectoryURL: URL
    private let sourceRootURL: URL
    private let templateHTML: String
    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var rendererFileURL: URL?

    init(markdown: String, baseDirectoryURL: URL, sourceRootURL: URL) throws {
        self.markdown = markdown
        self.baseDirectoryURL = baseDirectoryURL
        self.sourceRootURL = sourceRootURL
        self.templateHTML = try Self.loadTemplateHTML()

        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 1200), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func export() async throws -> Data {
        defer { cleanupRendererFileIfNeeded() }
        try await loadTemplate()
        try await waitUntilRendererReady(webView)
        try await webView.renderMarkdown(
            markdown,
            baseHref: baseDirectoryURL.absoluteString,
            sourceRootHref: sourceRootURL.absoluteString
        )
        try await Task.sleep(for: .milliseconds(250))
        return try await webView.singlePagePDFData()
    }

    private func loadTemplate() async throws {
        let rendererFileURL = try Self.prepareRendererFile(templateHTML: templateHTML)
        self.rendererFileURL = rendererFileURL
        let readAccessURL = Self.commonReadableRoot(for: [
            rendererFileURL.deletingLastPathComponent(),
            sourceRootURL,
            baseDirectoryURL
        ])

        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.loadFileURL(rendererFileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func waitUntilRendererReady(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            let result = try await webView.javascriptValue(
                "return !!(window.CodexRenderer && typeof window.CodexRenderer.renderMarkdownFromSource === 'function');"
            )

            if let isReady = result as? Bool, isReady {
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        throw RendererError.rendererNotReady
    }

    fileprivate static func loadTemplateHTML() throws -> String {
        guard let templateURL = Bundle.rendererBundle.rendererHTMLURL() else {
            throw RendererError.missingTemplate
        }

        guard let html = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw RendererError.missingTemplate
        }

        return html
    }

    fileprivate static func prepareRendererFile(templateHTML: String) throws -> URL {
        let fileManager = FileManager.default
        let rendererDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownPDFRendererRuntime", isDirectory: true)
        try fileManager.createDirectory(at: rendererDirectory, withIntermediateDirectories: true)

        let rendererFileURL = rendererDirectory.appendingPathComponent(UUID().uuidString + ".html")
        try templateHTML.write(to: rendererFileURL, atomically: true, encoding: .utf8)
        return rendererFileURL
    }

    fileprivate static func commonReadableRoot(for urls: [URL]) -> URL {
        let standardizedComponents = urls
            .map { $0.standardizedFileURL.pathComponents }
            .filter { !$0.isEmpty }

        guard var prefix = standardizedComponents.first else {
            return URL(fileURLWithPath: "/")
        }

        for components in standardizedComponents.dropFirst() {
            var sharedCount = 0
            while sharedCount < min(prefix.count, components.count), prefix[sharedCount] == components[sharedCount] {
                sharedCount += 1
            }
            prefix = Array(prefix.prefix(sharedCount))
        }

        if prefix.isEmpty {
            return URL(fileURLWithPath: "/")
        }

        let path = NSString.path(withComponents: prefix)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func cleanupRendererFileIfNeeded() {
        guard let rendererFileURL else {
            return
        }

        try? FileManager.default.removeItem(at: rendererFileURL)
        self.rendererFileURL = nil
    }
}

private enum RendererError: LocalizedError {
    case missingTemplate
    case previewUnavailable
    case rendererNotReady
    case invalidJavaScriptResult
    case invalidContentSize
    case invalidScrollPosition
    case snapshotFailed
    case imageConversionFailed
    case pdfContextCreationFailed
    case noMarkdownFound
    case zipExtractionFailed(String)
    case unsupportedMarkdownEncoding

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "找不到 HTML renderer 資源。"
        case .previewUnavailable:
            return "預覽尚未建立完成。"
        case .rendererNotReady:
            return "HTML renderer 尚未準備好。"
        case .invalidJavaScriptResult:
            return "JavaScript 回傳了無法解析的結果。"
        case .invalidContentSize:
            return "無法取得目前文件的內容尺寸。"
        case .invalidScrollPosition:
            return "無法將預覽捲動到正確位置。"
        case .snapshotFailed:
            return "無法擷取目前文件的快照。"
        case .imageConversionFailed:
            return "無法將快照轉成 PDF 可用影像。"
        case .pdfContextCreationFailed:
            return "無法建立 PDF 輸出內容。"
        case .noMarkdownFound:
            return "在匯入的資料夾或壓縮檔中找不到 `.md` 檔案。"
        case .zipExtractionFailed(let detail):
            return "壓縮檔解壓失敗：\(detail)"
        case .unsupportedMarkdownEncoding:
            return "無法辨識這份 Markdown 的文字編碼。"
        }
    }
}

struct ContentView: View {
    @StateObject private var previewStore = PreviewStore()

    @State private var sourceURL: URL?
    @State private var importedTemporaryRootURL: URL?
    @State private var markdownText = ContentView.defaultMarkdown
    @State private var baseDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    @State private var sourceRootURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    @State private var renderRequestID = UUID()
    @State private var isRendering = false
    @State private var isExporting = false
    @State private var statusMessage = "載入 `.md` 後即可預覽 Markdown / LaTeX / Mermaid。"
    @State private var lastError: String?

    var body: some View {
        ZStack {
            AppBackdrop()
            WindowGlassConfigurator()
                .frame(width: 0, height: 0)

            VStack(spacing: 16) {
                header
                MarkdownWebView(
                    markdownText: markdownText,
                    baseDirectoryURL: baseDirectoryURL,
                    sourceRootURL: sourceRootURL,
                    renderRequestID: renderRequestID,
                    isRendering: $isRendering,
                    statusMessage: $statusMessage,
                    lastError: $lastError,
                    previewStore: previewStore
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.55),
                                            Palette.soft.opacity(0.36)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.42), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 28, y: 12)
                .overlay {
                    if isRendering || isExporting {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Palette.accent)

                            Text(isExporting ? "匯出 PDF 中..." : "重新渲染中...")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.uiTextBright)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background {
                            Capsule()
                                .fill(.regularMaterial)
                                .overlay {
                                    Capsule()
                                        .fill(.white.opacity(0.34))
                                }
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
                    }
                }
            }
            .padding(24)
        }
        .background(Color.clear.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Markdown PDF Renderer")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.uiTextBright)
                    Text("匯入 `.md`，以與 HTML 模板相同的配色渲染 Markdown / LaTeX / Mermaid，再匯出成 PDF。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.uiMutedText)
                }

                Spacer(minLength: 20)

                Button("匯入 Markdown / 資料夾 / ZIP", action: importMarkdown)
                    .buttonStyle(GlassTintedButtonStyle(tint: Palette.accent))
                    .disabled(isRendering || isExporting)

                Button("匯出 PDF", action: beginExport)
                    .buttonStyle(GlassTintedButtonStyle(tint: Palette.accentBlue))
                    .disabled(isRendering || isExporting)
            }

            HStack(spacing: 12) {
                Label(sourceURL?.path(percentEncoded: false) ?? "尚未選擇檔案，正在顯示內建範例內容。", systemImage: "doc.text")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.uiTextBright.opacity(0.97))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(statusMessage)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        lastError == nil
                            ? Palette.uiSuccessText
                            : Palette.uiErrorText.mix(with: .white, by: 0.12)
                    )
                    .shadow(color: (lastError == nil ? Palette.uiSuccessText : Palette.uiErrorText).opacity(0.08), radius: 3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(0.62))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.background.opacity(0.28))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.82), lineWidth: 1)
            }
        }
    }

    private func importMarkdown() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .folder,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            UTType(filenameExtension: "zip") ?? .archive
        ]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            cleanupImportedTemporaryRootIfNeeded()

            let imported = try Self.loadImportedMarkdown(from: url)
            markdownText = imported.markdownText
            sourceURL = imported.markdownURL
            baseDirectoryURL = imported.baseDirectoryURL
            sourceRootURL = imported.sourceRootURL
            importedTemporaryRootURL = imported.extractedRootURL
            statusMessage = "已載入 \(imported.markdownURL.lastPathComponent)，準備渲染中。"
            lastError = nil
            renderRequestID = UUID()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "讀取失敗"
        }
    }

    private func beginExport() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "markdown-rendered") + ".pdf"
        panel.allowedContentTypes = [.pdf]

        guard panel.runModal() == .OK, let outputURL = panel.url else {
            return
        }

        isExporting = true
        statusMessage = "正在輸出 PDF..."
        lastError = nil

        Task {
            defer { isExporting = false }

            do {
                try await previewStore.exportPDF(to: outputURL)
                statusMessage = "PDF 已輸出到 \(outputURL.lastPathComponent)"
            } catch {
                lastError = error.localizedDescription
                statusMessage = "PDF 匯出失敗"
            }
        }
    }

    private static func readMarkdown(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let encodings: [String.Encoding] = [
            .utf8,
            .unicode,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32,
            .ascii
        ]

        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }

        throw RendererError.unsupportedMarkdownEncoding
    }

    private static func loadImportedMarkdown(from url: URL) throws -> ImportedMarkdownDocument {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])

        if resourceValues?.isDirectory == true {
            let markdownURL = try findPrimaryMarkdown(in: url)
            return ImportedMarkdownDocument(
                markdownURL: markdownURL,
                markdownText: try readMarkdown(from: markdownURL),
                baseDirectoryURL: markdownURL.deletingLastPathComponent(),
                sourceRootURL: url,
                extractedRootURL: nil
            )
        }

        if url.pathExtension.lowercased() == "zip" {
            let extractedRootURL = try extractZipToTemporaryDirectory(zipURL: url)
            let markdownURL = try findPrimaryMarkdown(in: extractedRootURL)
            return ImportedMarkdownDocument(
                markdownURL: markdownURL,
                markdownText: try readMarkdown(from: markdownURL),
                baseDirectoryURL: markdownURL.deletingLastPathComponent(),
                sourceRootURL: extractedRootURL,
                extractedRootURL: extractedRootURL
            )
        }

        return ImportedMarkdownDocument(
            markdownURL: url,
            markdownText: try readMarkdown(from: url),
            baseDirectoryURL: url.deletingLastPathComponent(),
            sourceRootURL: url.deletingLastPathComponent(),
            extractedRootURL: nil
        )
    }

    private static func findPrimaryMarkdown(in rootURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RendererError.noMarkdownFound
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey]),
                values.isRegularFile == true
            else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                candidates.append(fileURL)
            }
        }

        guard !candidates.isEmpty else {
            throw RendererError.noMarkdownFound
        }

        let preferredNames = ["content.md", "index.md", "readme.md", "README.md"]
        if let preferred = candidates.first(where: { preferredNames.contains($0.lastPathComponent) }) {
            return preferred
        }

        return candidates.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.first!
    }

    private static func extractZipToTemporaryDirectory(zipURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let extractionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownPDFRendererImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", zipURL.path, "-d", extractionRoot.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RendererError.zipExtractionFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RendererError.zipExtractionFailed(errorText?.isEmpty == false ? errorText! : "unzip 結束碼 \(process.terminationStatus)")
        }

        return extractionRoot
    }

    private func cleanupImportedTemporaryRootIfNeeded() {
        guard let importedTemporaryRootURL else {
            return
        }

        try? FileManager.default.removeItem(at: importedTemporaryRootURL)
        self.importedTemporaryRootURL = nil
    }

    private static let defaultMarkdown = #"""
# Markdown PDF Renderer

這是內建範例，可直接測試 Markdown、LaTeX 與 Mermaid 的預覽與 PDF 匯出。

## LaTeX

行內公式：$E = mc^2$

區塊公式：

$$
J(\theta) = \sum_{i=1}^{n}\left(y_i - \hat{y}_i\right)^2
$$

## Mermaid

```mermaid
flowchart TD
    A[選擇 Markdown] --> B[轉成 HTML]
    B --> C[MathJax 渲染公式]
    B --> D[Mermaid 渲染圖表]
    C --> E[匯出 PDF]
    D --> E
```

## 表格

| 項目 | 說明 |
| --- | --- |
| 主色 | `#141413` |
| 背景 | `#FAF9F5` |
| Accent | `#D97757` |
"""#
}

private struct MarkdownWebView: NSViewRepresentable {
    let markdownText: String
    let baseDirectoryURL: URL
    let sourceRootURL: URL
    let renderRequestID: UUID

    @Binding var isRendering: Bool
    @Binding var statusMessage: String
    @Binding var lastError: String?

    @ObservedObject var previewStore: PreviewStore

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isRendering: $isRendering,
            statusMessage: $statusMessage,
            lastError: $lastError,
            previewStore: previewStore
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        previewStore.updateSource(
            markdown: markdownText,
            baseDirectoryURL: baseDirectoryURL,
            sourceRootURL: sourceRootURL
        )
        context.coordinator.prepareRender(
            RenderRequest(
                id: renderRequestID,
                markdown: markdownText,
                baseDirectoryURL: baseDirectoryURL,
                sourceRootURL: sourceRootURL
            )
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var isRendering: Bool
        @Binding private var statusMessage: String
        @Binding private var lastError: String?

        private let previewStore: PreviewStore
        private let templateHTML: String?
        private weak var webView: WKWebView?
        private var pendingRequest: RenderRequest?
        private var lastAppliedRequestID: UUID?
        private var isPageLoaded = false
        private var renderTask: Task<Void, Never>?
        private var rendererFileURL: URL?

        init(
            isRendering: Binding<Bool>,
            statusMessage: Binding<String>,
            lastError: Binding<String?>,
            previewStore: PreviewStore
        ) {
            _isRendering = isRendering
            _statusMessage = statusMessage
            _lastError = lastError
            self.previewStore = previewStore
            self.templateHTML = try? OffscreenPDFExporter.loadTemplateHTML()
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func prepareRender(_ request: RenderRequest) {
            guard request.id != lastAppliedRequestID else {
                return
            }

            pendingRequest = request
            lastAppliedRequestID = request.id
            isPageLoaded = false
            lastError = nil

            guard let webView else {
                lastError = RendererError.previewUnavailable.localizedDescription
                statusMessage = "預覽初始化失敗"
                return
            }

            guard let templateHTML else {
                lastError = RendererError.missingTemplate.localizedDescription
                statusMessage = "找不到 renderer 樣板"
                return
            }

            isRendering = true
            statusMessage = "載入 HTML renderer..."
            do {
                cleanupRendererFileIfNeeded()
                let rendererFileURL = try OffscreenPDFExporter.prepareRendererFile(templateHTML: templateHTML)
                self.rendererFileURL = rendererFileURL
                let readAccessURL = OffscreenPDFExporter.commonReadableRoot(for: [
                    rendererFileURL.deletingLastPathComponent(),
                    request.sourceRootURL,
                    request.baseDirectoryURL
                ])
                webView.loadFileURL(rendererFileURL, allowingReadAccessTo: readAccessURL)
            } catch {
                isRendering = false
                lastError = error.localizedDescription
                statusMessage = "HTML renderer 載入失敗"
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            runPendingRenderIfNeeded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isRendering = false
            lastError = error.localizedDescription
            statusMessage = "HTML renderer 載入失敗"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isRendering = false
            lastError = error.localizedDescription
            statusMessage = "HTML renderer 啟動失敗"
        }

        private func runPendingRenderIfNeeded() {
            guard isPageLoaded, let webView, let request = pendingRequest else {
                return
            }

            renderTask?.cancel()
            renderTask = Task { @MainActor in
                do {
                    statusMessage = "等待 JS renderer 就緒..."
                    try await waitUntilRendererReady(webView)
                    statusMessage = "渲染 Markdown / LaTeX / Mermaid..."
                    try await webView.renderMarkdown(
                        request.markdown,
                        baseHref: request.baseDirectoryURL.absoluteString,
                        sourceRootHref: request.sourceRootURL.absoluteString
                    )
                    statusMessage = "渲染完成，可匯出 PDF。"
                    isRendering = false
                    lastError = nil
                    pendingRequest = nil
                } catch {
                    isRendering = false
                    lastError = error.localizedDescription
                    statusMessage = "渲染失敗"
                }
            }
        }

        private func waitUntilRendererReady(_ webView: WKWebView) async throws {
            for _ in 0..<100 {
                let result = try await webView.javascriptValue(
                    "return !!(window.CodexRenderer && typeof window.CodexRenderer.renderMarkdownFromSource === 'function');"
                )

                if let isReady = result as? Bool, isReady {
                    return
                }

                try await Task.sleep(for: .milliseconds(100))
            }

            throw RendererError.rendererNotReady
        }

        private func cleanupRendererFileIfNeeded() {
            guard let rendererFileURL else {
                return
            }

            try? FileManager.default.removeItem(at: rendererFileURL)
            self.rendererFileURL = nil
        }
    }
}

private extension WKWebView {
    @MainActor
    func javascriptValue(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
    }

    @MainActor
    func renderMarkdown(_ markdown: String, baseHref: String, sourceRootHref: String) async throws {
        let result = try await javascriptValue(
            "return window.CodexRenderer.renderMarkdownFromSource(markdown, baseHref, sourceRootHref);",
            arguments: [
                "markdown": markdown,
                "baseHref": baseHref,
                "sourceRootHref": sourceRootHref
            ]
        )

        guard result as? String == "ok" else {
            throw RendererError.invalidJavaScriptResult
        }
    }

    @MainActor
    func singlePagePDFData() async throws -> Data {
        let metrics = try await exportMetrics()
        let pageRect = CGRect(x: 0, y: 0, width: metrics.width, height: metrics.height)
        let maxScrollY = max(metrics.height - metrics.viewportHeight, 0)

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            throw RendererError.pdfContextCreationFailed
        }

        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RendererError.pdfContextCreationFailed
        }

        let pageInfo = [kCGPDFContextMediaBox as String: pageRect] as CFDictionary
        context.beginPDFPage(pageInfo)

        let originalOffset = try await currentScrollOffset()
        defer {
            Task { @MainActor in
                try? await setScrollOffset(originalOffset)
            }
        }

        let viewportHeight = max(metrics.viewportHeight, 1)
        let tileHeight = max(min(viewportHeight, 1600), 400)
        let snapshotScale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 2)
        let snapshotWidth = Int(pageRect.width * snapshotScale)

        var logicalY: CGFloat = 0
        while logicalY < pageRect.height {
            let currentTileHeight = min(tileHeight, pageRect.height - logicalY)
            let requestedScrollY = min(logicalY, maxScrollY)
            let actualScrollY = try await setScrollOffset(requestedScrollY)
            let localOffsetY = max(logicalY - actualScrollY, 0)
            let snapshotRect = CGRect(x: 0, y: localOffsetY, width: pageRect.width, height: currentTileHeight)
            let image = try await snapshot(rect: snapshotRect, snapshotWidth: snapshotWidth)
            guard let cgImage = image.cgImage else {
                throw RendererError.imageConversionFailed
            }

            let drawRect = CGRect(
                x: 0,
                y: pageRect.height - logicalY - currentTileHeight,
                width: pageRect.width,
                height: currentTileHeight
            )
            context.draw(cgImage, in: drawRect)
            logicalY += currentTileHeight
        }

        context.endPDFPage()
        context.closePDF()
        return mutableData as Data
    }

    @MainActor
    private func exportMetrics() async throws -> ExportMetrics {
        let result = try await javascriptValue(
            "return window.CodexRenderer.getExportMetrics();"
        )

        guard
            let dictionary = result as? [String: Any],
            let rawWidth = dictionary["width"] as? Double,
            let rawHeight = dictionary["height"] as? Double,
            let rawViewportHeight = dictionary["viewportHeight"] as? Double
        else {
            throw RendererError.invalidContentSize
        }

        let width = max(CGFloat(rawWidth), bounds.width, 640)
        let height = max(CGFloat(rawHeight), 1) + 1
        let viewportHeight = max(CGFloat(rawViewportHeight), bounds.height, 1)
        return ExportMetrics(width: width, height: height, viewportHeight: viewportHeight)
    }

    @MainActor
    private func snapshot(rect: CGRect, snapshotWidth: Int) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: snapshotWidth)

        return try await withCheckedThrowingContinuation { continuation in
            takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: RendererError.snapshotFailed)
                }
            }
        }
    }

    @MainActor
    private func currentScrollOffset() async throws -> CGFloat {
        let result = try await javascriptValue("return window.scrollY;")
        guard let scrollY = result as? Double else {
            throw RendererError.invalidScrollPosition
        }

        return CGFloat(scrollY)
    }

    @MainActor
    private func setScrollOffset(_ y: CGFloat) async throws -> CGFloat {
        _ = try await javascriptValue(
            "return window.CodexRenderer.setExportScrollOffset(y);",
            arguments: ["y": y]
        )

        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            let actualY = try await currentScrollOffset()
            if abs(actualY - y) <= 2 || actualY >= y || abs(actualY - max(y, 0)) <= 4 {
                return actualY
            }
        }

        let fallbackY = try await currentScrollOffset()
        if fallbackY >= 0 {
            return fallbackY
        }

        throw RendererError.invalidScrollPosition
    }
}

private extension NSImage {
    var cgImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

private struct GlassTintedButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        GlassTintedButtonBody(configuration: configuration, tint: tint)
    }
}

private struct GlassTintedButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        tint.opacity(topTintOpacity),
                                        tint.opacity(bottomTintOpacity)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        Capsule()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        tint.opacity(highlightOpacity),
                                        .clear
                                    ],
                                    center: .top,
                                    startRadius: 4,
                                    endRadius: 40
                                )
                            )
                            .blendMode(.plusLighter)
                    }
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                tint.mix(with: .white, by: 0.52).opacity(borderOpacity),
                                tint.opacity(borderOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: configuration.isPressed ? 1.4 : 1.05
                    )
            }
            .shadow(color: tint.opacity(shadowOpacity), radius: configuration.isPressed ? 20 : 16, y: 8)
            .shadow(color: tint.opacity(outerGlowOpacity), radius: configuration.isPressed ? 16 : 10)
            .brightness(configuration.isPressed ? 0.1 : (isHovered ? 0.045 : 0))
            .saturation(configuration.isPressed ? 1.16 : (isHovered ? 1.08 : 1))
            .scaleEffect(configuration.isPressed ? 0.982 : (isHovered ? 1.01 : 1))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var labelColor: Color {
        .white.opacity(configuration.isPressed ? 0.98 : 0.96)
    }

    private var topTintOpacity: Double {
        if configuration.isPressed { return 0.82 }
        if isHovered { return 0.72 }
        return 0.66
    }

    private var bottomTintOpacity: Double {
        if configuration.isPressed { return 0.58 }
        if isHovered { return 0.5 }
        return 0.46
    }

    private var highlightOpacity: Double {
        if configuration.isPressed { return 0.24 }
        if isHovered { return 0.18 }
        return 0.12
    }

    private var borderOpacity: Double {
        if configuration.isPressed { return 0.95 }
        if isHovered { return 0.78 }
        return 0.72
    }

    private var shadowOpacity: Double {
        if configuration.isPressed { return 0.18 }
        if isHovered { return 0.14 }
        return 0.12
    }

    private var outerGlowOpacity: Double {
        if configuration.isPressed { return 0.08 }
        if isHovered { return 0.06 }
        return 0.04
    }
}

private struct AppBackdrop: View {
    var body: some View {
        ZStack {
            VibrantBackdrop()

            Rectangle()
                .fill(Palette.background.opacity(0.72))
        }
        .ignoresSafeArea()
    }
}

private struct VibrantBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct WindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(from: nsView)
        }
    }

    private func configureWindow(from view: NSView) {
        guard let window = view.window else {
            return
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    func mix(with other: Color, by amount: Double) -> Color {
        let clamped = min(max(amount, 0), 1)
        guard
            let lhs = NSColor(self).usingColorSpace(.deviceRGB),
            let rhs = NSColor(other).usingColorSpace(.deviceRGB)
        else {
            return self
        }

        let red = lhs.redComponent + (rhs.redComponent - lhs.redComponent) * clamped
        let green = lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * clamped
        let blue = lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * clamped
        let alpha = lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * clamped

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
