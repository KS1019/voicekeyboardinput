import Foundation
import SwiftUI

struct VoiceCompositionExperiment {
    enum Mode: String, CaseIterable { case literal = "Literal", command = "Command" }
    enum Effect: Equatable { case insert(String), language(String) }

    private(set) var generation = UUID()
    private(set) var draft = ""
    private(set) var mode: Mode = .literal
    var shouldOfferCommit: Bool { draft.count >= 160 }

    mutating func begin(mode: Mode) -> UUID {
        generation = UUID()
        draft = ""
        self.mode = mode
        return generation
    }

    @discardableResult
    mutating func update(cumulativeTranscript: String, generation: UUID) -> Bool {
        guard generation == self.generation, cumulativeTranscript.count <= 512 else { return false }
        draft = cumulativeTranscript
        return true
    }

    mutating func commit(generation: UUID) -> Effect? {
        guard generation == self.generation, !draft.isEmpty else { return nil }
        let text = draft
        let mode = mode
        _ = begin(mode: .literal)
        guard mode == .command else { return .insert(text) }
        // Only a whole, explicit command utterance can change behavior.
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch command {
        case "改行して", "改行", "new line": return .insert("\n")
        case "ここから日本語", "switch to japanese": return .language("ja-JP")
        case "ここから英語", "switch to english": return .language("en-US")
        default: return .insert(text)
        }
    }
}

struct VoiceCompositionExperimentView: View {
    @State private var experiment = VoiceCompositionExperiment()
    @State private var transcript = ""
    @State private var output = ""
    @State private var language = "Automatic (not connected)"
    @State private var message = ""
    @State private var mode = VoiceCompositionExperiment.Mode.literal
    @FocusState private var transcriptIsFocused: Bool

    var body: some View {
        Form {
            Section("Offline composition experiment") {
                Text("Type or paste a transcript to simulate recognition. This lab does not record audio or edit another app.")
                Picker("Interpretation", selection: $mode) {
                    ForEach(VoiceCompositionExperiment.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("composition.mode")
                .onChange(of: mode) { _, value in
                    _ = experiment.begin(mode: value)
                    transcript = ""
                }
                TextField("Transcript", text: $transcript, axis: .vertical)
                    .focused($transcriptIsFocused)
                    .accessibilityIdentifier("composition.transcript")
                Button("Preview draft") {
                    transcriptIsFocused = false
                    message = experiment.update(cumulativeTranscript: transcript, generation: experiment.generation)
                        ? "Draft updated; nothing inserted." : "Limit is 512 characters. Your input is still in the field."
                }
                .accessibilityIdentifier("composition.preview")
                Text(experiment.draft.isEmpty ? "No draft" : experiment.draft)
                    .accessibilityIdentifier("composition.draft")
                if experiment.shouldOfferCommit { Text("Long draft: review and commit this passage.") }
                Button("Commit utterance") { commit() }
                    .accessibilityIdentifier("composition.commit")
                Button("Cancel / change destination") {
                    _ = experiment.begin(mode: .literal)
                    mode = .literal
                    transcript = ""
                    message = "Pending draft cancelled. Late results are invalid."
                }
                Text(message).font(.footnote)
            }
            Section("Result in this lab only") {
                Text(output.isEmpty ? "Nothing inserted" : output)
                    .accessibilityIdentifier("composition.output")
                Text(language).accessibilityIdentifier("composition.language")
                Text("Command mode accepts a whole utterance: 改行して, ここから日本語, ここから英語, or their English equivalents. Other phrases remain literal. Each commit returns to Literal mode.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Composition Lab")
    }

    private func commit() {
        transcriptIsFocused = false
        guard experiment.update(cumulativeTranscript: transcript, generation: experiment.generation) else {
            message = "Limit is 512 characters. Your input is still in the field."
            return
        }
        guard let effect = experiment.commit(generation: experiment.generation) else { return }
        switch effect {
        case .insert(let text): output += text
        case .language(let identifier): language = identifier
        }
        transcript = ""
        mode = .literal
        message = "Committed in the lab only."
    }
}
