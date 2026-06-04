import SharedCore
import SwiftUI

/// Shared model picker for any "this step uses Ollama" setting.
///
/// Lists the models
/// actually installed in Ollama (from `OllamaProbe` → `/api/tags`) as selectable
/// rows; falls back to a free-text field with a pull hint when none are found.
/// Used by both the meeting notes model and the dictation cleanup model so the
/// behaviour is identical everywhere Ollama is selectable.
@MainActor
struct OllamaModelPicker: View {
    let installed: [String]
    let key: String
    @Binding var value: String

    var body: some View {
        if installed.isEmpty {
            SettingsRow(
                key: key,
                hint:
                    "No Ollama models found. Start Ollama, then in Terminal run “ollama pull llama3.2” and reopen Settings.",
                showDivider: false
            ) {
                TextField("llama3.2", text: $value)
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.body)
                    .frame(width: 220)
            }
        } else {
            ForEach(Array(installed.enumerated()), id: \.element) { index, modelName in
                BrutalistSelectRow(
                    title: modelName,
                    detail: "Installed",
                    selected: value == modelName,
                    showDivider: index != installed.count - 1,
                    action: { value = modelName }
                )
            }
        }
    }
}

/// Installed Ollama model names (most recent first as Ollama returns them), or
/// `[]` when Ollama isn't running.
///
/// Shared by every settings view that lets the
/// user pick an Ollama model.
@MainActor
enum OllamaModels {
    static func installed() async -> [String] {
        await OllamaProbe().probe().models.map(\.name)
    }
}
