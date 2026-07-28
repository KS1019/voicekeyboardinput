import SwiftUI
import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels

private actor LiteralTranscriptPreviewWorker {
    func preview(
        using pipeline: LiteralTranscriptCommandPipeline,
        transcript: String,
        documentContext: String
    ) -> LiteralTranscriptPreview {
        guard !Task.isCancelled else {
            return LiteralTranscriptPreview(elements: [], operations: [])
        }
        return pipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContext
        )
    }
}

struct MenuBarContentView: View {
    private static let maximumDisplayedRows = 64

    private enum PreviewLocale: String, CaseIterable, Identifiable {
        case english = "en-US"
        case japanese = "ja-JP"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .english:
                "English"
            case .japanese:
                "日本語"
            }
        }
    }

    @State private var transcript = "comma newline"
    @State private var documentContext = ""
    @State private var selectedLocale: PreviewLocale = .english
    @State private var preview = LiteralTranscriptPreview(
        elements: [],
        operations: []
    )
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration: UInt64 = 0
    // Keep the actor identity in SwiftUI state. A View value is recreated
    // frequently; a plain stored actor would allow cancelled preview tasks to
    // queue work on multiple workers at once.
    @State private var previewWorker = LiteralTranscriptPreviewWorker()

    private var pipeline: LiteralTranscriptCommandPipeline {
        LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: selectedLocale.rawValue)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcript Tester", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Button("Preview", action: previewTranscript)
                    .keyboardShortcut(.return, modifiers: [.command])
            }

            Text("Literal transcript")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: boundedBinding(for: $transcript))
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )
                .accessibilityLabel("Literal transcript")

            TextField(
                "Text immediately before insertion",
                text: boundedBinding(for: $documentContext)
            )
            .textFieldStyle(.roundedBorder)

            Picker(
                "Locale",
                selection: Binding(
                    get: { selectedLocale },
                    set: {
                        selectedLocale = $0
                        invalidatePreview()
                    }
                )
            ) {
                ForEach(PreviewLocale.allCases) { locale in
                    Text(locale.title).tag(locale)
                }
            }
            .pickerStyle(.segmented)

            Divider()
            previewSection
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: previewTranscript)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var previewSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("Parsed Elements")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.elements.prefix(Self.maximumDisplayedRows).enumerated()),
                    id: \.offset
                ) { index, element in
                    Text("\(index + 1). \(elementDescription(element))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if preview.elements.count > Self.maximumDisplayedRows {
                    Text("… \(preview.elements.count - Self.maximumDisplayedRows) more elements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if preview.elements.isEmpty {
                    Text("No elements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Planned Operations")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.operations.prefix(Self.maximumDisplayedRows).enumerated()),
                    id: \.offset
                ) { index, operation in
                    Text("\(index + 1). \(operationDescription(operation))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if preview.operations.count > Self.maximumDisplayedRows {
                    Text("… \(preview.operations.count - Self.maximumDisplayedRows) more operations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if preview.operations.isEmpty {
                    Text("No operations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func previewTranscript() {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        let pipeline = pipeline
        let transcript = transcript
        let documentContext = documentContext
        previewTask = Task { @MainActor in
            let nextPreview = await previewWorker.preview(
                using: pipeline,
                transcript: transcript,
                documentContext: documentContext
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            preview = nextPreview
        }
    }

    private func boundedBinding(for source: Binding<String>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: {
                let bounded = MenuBarInputLimits.bounded($0)
                guard bounded != source.wrappedValue else { return }
                source.wrappedValue = bounded
                invalidatePreview()
            }
        )
    }

    private func invalidatePreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
    }

    private func elementDescription(
        _ element: LiteralTranscriptElement
    ) -> String {
        MenuBarDebugText.elementDescription(element)
    }

    private func commandDescription(
        _ command: LiteralTranscriptCommand
    ) -> String {
        MenuBarDebugText.commandDescription(command)
    }

    private func operationDescription(_ operation: TextOperation) -> String {
        MenuBarDebugText.operationDescription(operation)
    }
}

enum MenuBarInputLimits {
    static func bounded(_ value: String) -> String {
        // Limit Unicode scalars before forming Characters. A single grapheme
        // can contain millions of combining scalars, and Character iteration
        // would otherwise scan the complete paste synchronously on the main
        // actor before any limit could be applied.
        let scalarBoundedValue = String(
            value.unicodeScalars.prefix(VoiceKeyboardTextLimits.maximumUnicodeScalarCount)
        )
        var bounded = String()
        var characterCount = 0
        var scalarCount = 0
        var utf8ByteCount = 0

        for character in scalarBoundedValue {
            let nextScalarCount = scalarCount + character.unicodeScalars.count
            let nextUTF8ByteCount = utf8ByteCount + character.utf8.count
            guard characterCount < VoiceKeyboardTextLimits.maximumCharacterCount,
                  nextScalarCount <= VoiceKeyboardTextLimits.maximumUnicodeScalarCount,
                  nextUTF8ByteCount <= VoiceKeyboardTextLimits.maximumUTF8ByteCount else {
                return bounded
            }
            bounded.append(character)
            characterCount += 1
            scalarCount = nextScalarCount
            utf8ByteCount = nextUTF8ByteCount
        }

        return bounded
    }
}

enum MenuBarDebugText {
    private static let maximumLiteralLength = 2_048

    static func elementDescription(_ element: LiteralTranscriptElement) -> String {
        switch element {
        case .text(let value):
            "text(\(literal(value)))"
        case .command(let command):
            "command(\(commandDescription(command)))"
        }
    }

    static func commandDescription(_ command: LiteralTranscriptCommand) -> String {
        switch command {
        case .insertText(let value):
            "insertText(\(literal(value)))"
        case .deleteWord:
            "deleteWord"
        case .deleteSentence:
            "deleteSentence"
        case .unsupportedShortcut(let phrase):
            "unsupportedShortcut(\(literal(phrase)))"
        }
    }

    static func operationDescription(_ operation: TextOperation) -> String {
        switch operation {
        case .insertText(let value):
            "insertText(\(literal(value)))"
        case .deleteBackward(let count):
            "deleteBackward(count: \(count.value))"
        case .showUnsupportedCommand(let phrase):
            "showUnsupportedCommand(\(literal(phrase)))"
        }
    }

    private static func literal(_ value: String) -> String {
        guard value.count > maximumLiteralLength else {
            return String(reflecting: value)
        }
        let remainingCount = value.count - maximumLiteralLength
        let boundedValue = String(value.prefix(maximumLiteralLength))
            + "… (\(remainingCount) more characters)"
        return String(reflecting: boundedValue)
    }
}
