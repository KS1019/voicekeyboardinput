import SwiftUI
import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels

struct MenuBarContentView: View {
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

    @State private var transcript = "hello comma world newline"
    @State private var documentContext = ""
    @State private var selectedLocale: PreviewLocale = .english
    @State private var preview = LiteralTranscriptPreview(
        elements: [],
        operations: []
    )

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
            TextEditor(text: $transcript)
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )

            TextField(
                "Text immediately before insertion",
                text: $documentContext
            )
            .textFieldStyle(.roundedBorder)

            Picker("Locale", selection: $selectedLocale) {
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
    }

    private var previewSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parsed Elements")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.elements.enumerated()),
                    id: \.offset
                ) { index, element in
                    Text("\(index + 1). \(elementDescription(element))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if preview.elements.isEmpty {
                    Text("No elements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Planned Operations")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.operations.enumerated()),
                    id: \.offset
                ) { index, operation in
                    Text("\(index + 1). \(operationDescription(operation))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        preview = pipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContext
        )
    }

    private func elementDescription(
        _ element: LiteralTranscriptElement
    ) -> String {
        switch element {
        case .text(let value):
            "text(\"\(value)\")"
        case .command(let command):
            "command(\(commandDescription(command)))"
        }
    }

    private func commandDescription(
        _ command: LiteralTranscriptCommand
    ) -> String {
        switch command {
        case .insertText(let value):
            "insertText(\"\(value)\")"
        case .deleteWord:
            "deleteWord"
        case .deleteSentence:
            "deleteSentence"
        case .unsupportedShortcut(let phrase):
            "unsupportedShortcut(\"\(phrase)\")"
        }
    }

    private func operationDescription(_ operation: TextOperation) -> String {
        switch operation {
        case .insertText(let value):
            "insertText(\"\(value)\")"
        case .deleteBackward(let count):
            "deleteBackward(count: \(count.value))"
        case .showUnsupportedCommand(let phrase):
            "showUnsupportedCommand(\"\(phrase)\")"
        }
    }
}
