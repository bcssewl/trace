import SharedCore
import SwiftUI

/// The reusable "which model for this stage" selector row (BAS-49) — the single
/// component behind every per-task model picker, replacing the six near-identical
/// `*ModelRow` builders (cleanup / notes / title / categorization / library-Q&A /
/// conversation-state).
///
/// It renders the right control for the stage's *current*
/// provider: a static caption for the deterministic and Apple FM cases, the
/// shared `OllamaModelPicker` for Ollama, and an OpenRouter slug field otherwise.
///
/// Being a `@MainActor` `View`, its binding closures capture the `@MainActor`
/// `state` inline and read/write `state.model(for:provider:)` directly. That is
/// precisely what keeps it free of the strict-concurrency `@Sendable`-closure
/// warning that a stored get/set-forwarding helper would trip — the reason the
/// legacy rows were six separate copies rather than one shared helper.
@MainActor
struct StageModelRow: View {
    @Environment(\.brutalistPalette) private var palette
    let state: AppStateModel
    let stage: LLMRouteStage
    let installedOllamaModels: [String]
    var label: String
    var openRouterPlaceholder: String = "google/gemini-3.1-flash-lite"
    var openRouterHint: String? = nil
    var showDivider: Bool = false
    /// Additional stages to mirror this row's model id into — so one control can
    /// drive a whole group (e.g. the meeting notes/title/categorization trio) from
    /// a single field.
    ///
    /// Empty for an ordinary single-stage row.
    var mirrorStages: [LLMRouteStage] = []

    var body: some View {
        switch state.provider(for: stage) {
        case .deterministic:
            staticRow("No model needed — built in")
        case .appleFM:
            staticRow("Apple Intelligence, built into macOS")
        case .ollama:
            OllamaModelPicker(
                installed: installedOllamaModels,
                key: label,
                value: Binding(
                    get: { state.model(for: stage, provider: .ollama) },
                    set: { newValue in
                        state.setModel(newValue, for: stage, provider: .ollama)
                        for mirror in mirrorStages { state.setModel(newValue, for: mirror, provider: .ollama) }
                    }
                )
            )
        case .openRouter:
            SettingsRow(key: label, hint: openRouterHint, showDivider: showDivider) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        openRouterPlaceholder,
                        text: Binding(
                            get: { state.model(for: stage, provider: .openRouter) },
                            set: { newValue in
                                state.setModel(newValue, for: stage, provider: .openRouter)
                                for mirror in mirrorStages {
                                    state.setModel(newValue, for: mirror, provider: .openRouter)
                                }
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.body)
                    .frame(width: 320)
                    // The slug must match OpenRouter's exact model id; link straight
                    // to their model list so it's one click to copy the right one.
                    Link(
                        "Not sure of the name? Browse models at openrouter.ai/models ↗",
                        destination: URL(string: "https://openrouter.ai/models")!
                    )
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.primary.color)
                }
            }
        case .anthropic, .chatgpt, .minimax:
            connectableModelRow(state.provider(for: stage))
        }
    }

    /// Free-text model id for a connected cloud provider (Anthropic / ChatGPT /
    /// MiniMax) — the OpenRouter-slug pattern, seeded + hinted with the provider's
    /// curated model ids (BAS-60).
    ///
    /// Free text on purpose: a newer model id is never
    /// blocked by the built-in suggestion list going stale.
    @ViewBuilder
    private func connectableModelRow(_ provider: DictationCleanupProvider) -> some View {
        let suggestions = provider.modelProvider?.defaultModels ?? []
        SettingsRow(
            key: label,
            hint: suggestions.isEmpty ? nil : "The model name — for example \(suggestions.joined(separator: ", ")).",
            showDivider: showDivider
        ) {
            TextField(
                suggestions.first ?? "model id",
                text: Binding(
                    get: { state.model(for: stage, provider: provider) },
                    set: { newValue in
                        state.setModel(newValue, for: stage, provider: provider)
                        for mirror in mirrorStages { state.setModel(newValue, for: mirror, provider: provider) }
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(BrutalistTypography.body)
            .frame(width: 320)
        }
    }

    private func staticRow(_ text: String) -> some View {
        SettingsRow(key: label, showDivider: showDivider) {
            Text(text)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
    }
}
