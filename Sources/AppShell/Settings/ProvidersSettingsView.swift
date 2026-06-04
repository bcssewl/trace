import AppKit
import SharedCore
import SwiftUI

/// Settings → LLM Router → provider connection cards — one unified surface for
/// every credential the app can use: BYOK API-key cards for OpenRouter, OpenAI
/// direct, Anthropic, and MiniMax, plus an OAuth sign-in card for ChatGPT (Codex)
/// via the system browser + loopback.
///
/// Saving or removing a key posts
/// `.traceProvidersChanged`, which the per-stage routing pickers observe so a
/// newly connected provider becomes routable immediately (BAS-37 / BAS-60).
///
/// The four key cards used to live in two separate hand-rolled views
/// (`OpenAICompatSettingsView` for OpenRouter/OpenAI; this view for
/// Anthropic/MiniMax) that had drifted apart — only one pair had a Remove button
/// and a saved-state placeholder, and they confirmed saves in different spots.
/// `ProviderKeyCard` is now the single card all four render through, so they can
/// no longer diverge.
@MainActor
public struct ProvidersSettingsView: View {
    @State private var chatgptSignedIn = false
    @State private var chatgptAccount: String?
    @State private var chatgptStatus = ""
    @State private var signingIn = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // OpenRouter keeps its richer copy + `sk-or-…` placeholder (the catalog
            // blurb is terser); the account is read from the catalog so it can't
            // drift from the route's Keychain lookup.
            ProviderKeyCard(
                title: "OpenRouter",
                hint:
                    "A single key gives you GPT-5, Claude, Gemini, Mistral, DeepSeek, and many more — the easiest way to use cloud models in Trace.",
                placeholder: "sk-or-…",
                account: ModelProvider.openRouter.keychainAccount ?? "openrouter",
                logo: .openRouter
            )
            // Connect cloud LLM providers — keys read straight from the catalog
            // (display name, blurb, placeholder, suggested models, account).
            ProviderKeyCard(provider: .anthropic, logo: .anthropic)
            ProviderKeyCard(provider: .minimax)
            // OpenAI direct is NOT an LLM-route provider — its key powers cloud
            // Whisper transcription (`CloudASRBackend`) and OpenAI embeddings
            // (`EmbeddingProviderChoice`), both keyed on the same "openai" account.
            ProviderKeyCard(
                title: "OpenAI",
                hint:
                    "Connect to OpenAI directly for cloud transcription and search. To use OpenAI’s text models for notes and the coach, add them through OpenRouter above.",
                placeholder: "sk-…",
                account: "openai",
                logo: .openAI
            )
            chatgptCard
        }
        .task { await refreshChatGPTState() }
    }

    // MARK: - ChatGPT (Codex) OAuth

    private var chatgptCard: some View {
        SettingsGroup(ModelProvider.chatgpt.displayName, tag: chatgptSignedIn ? "Connected" : "Sign in") {
            SettingsRow(
                key: chatgptSignedIn ? "Connected" : "Sign in with ChatGPT",
                hint: signInHint,
                showDivider: false
            ) {
                if chatgptSignedIn {
                    BrutalistButton("Sign out", kind: .ghost) { Task { await signOutChatGPT() } }
                } else {
                    BrutalistButton(signingIn ? "Waiting for your browser…" : "Sign in", kind: .primary) {
                        startChatGPTSignIn()
                    }
                    .disabled(signingIn)
                }
            }
        }
    }

    private var signInHint: String {
        if !chatgptStatus.isEmpty { return chatgptStatus }
        if chatgptSignedIn {
            return chatgptAccount.map { "Signed in as \($0)" } ?? "Connected through your ChatGPT subscription."
        }
        return ModelProvider.chatgpt.connectBlurb
    }

    private func startChatGPTSignIn() {
        guard !signingIn else { return }
        signingIn = true
        chatgptStatus = ""
        Task { @MainActor in
            do {
                let credential = try await CodexSignInFlow().signIn(openURL: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                chatgptSignedIn = true
                chatgptAccount = credential.accountId
                chatgptStatus = ""
                NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
            } catch {
                chatgptStatus = "Sign-in failed: \(error.localizedDescription)"
            }
            signingIn = false
        }
    }

    private func signOutChatGPT() async {
        try? await OAuthTokenStore(account: CodexAuth.keychainAccount).clear()
        chatgptSignedIn = false
        chatgptAccount = nil
        chatgptStatus = "Signed out."
        NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
    }

    private func refreshChatGPTState() async {
        let credential = try? await OAuthTokenStore(account: CodexAuth.keychainAccount).current()
        chatgptSignedIn = credential != nil
        chatgptAccount = credential?.accountId
    }
}

// MARK: - Reusable BYOK key card

/// One BYOK API-key card: a `SecureField` whose value is stored in the Keychain,
/// with a Save/Update action, a Remove action once stored, a "SAVED ✓"/"BYOK"
/// tag, a saved-state placeholder, and an inline status line.
///
/// Every key provider
/// (OpenRouter, OpenAI direct, Anthropic, MiniMax) renders through this so the
/// cards stay identical in behavior. Self-contained: it reflects the stored key
/// on appear and posts `.traceProvidersChanged` on save/remove.
@MainActor
struct ProviderKeyCard: View {
    let title: String
    let hint: String
    let placeholder: String
    let account: String
    /// Optional brand mark; `nil` for providers without one (e.g. MiniMax).
    let logo: BrandLogo?
    /// Optional suggested-models line shown beneath the key (catalog defaults).
    let modelsLine: String?

    @State private var draft = ""
    @State private var isSet = false
    @State private var status = ""
    private let keychain = KeychainSecrets()

    init(
        title: String,
        hint: String,
        placeholder: String,
        account: String,
        logo: BrandLogo? = nil,
        modelsLine: String? = nil
    ) {
        self.title = title
        self.hint = hint
        self.placeholder = placeholder
        self.account = account
        self.logo = logo
        self.modelsLine = modelsLine
    }

    /// Catalog-backed card — pulls display name, blurb, placeholder, account, and
    /// suggested models straight from `ModelProvider` so the UI can't drift from
    /// the router's single source of truth.
    init(provider: ModelProvider, logo: BrandLogo? = nil, showModels: Bool = true) {
        self.init(
            title: provider.displayName,
            hint: provider.connectBlurb,
            placeholder: provider.keyPlaceholder,
            account: provider.keychainAccount ?? "",
            logo: logo,
            modelsLine: showModels ? provider.defaultModels.joined(separator: " · ") : nil
        )
    }

    var body: some View {
        SettingsGroup(title, tag: isSet ? "Connected" : "Add your key") {
            SettingsRow(
                key: "API key",
                hint: hint,
                showDivider: isSet || modelsLine != nil || !status.isEmpty
            ) {
                HStack(spacing: 8) {
                    if let logo { BrandLogoView(logo, size: 16) }
                    SecureField(isSet ? "•••• saved — type to replace" : placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(BrutalistTypography.mono11)
                        .frame(width: 240)
                    BrutalistButton(isSet ? "Update" : "Save", kind: .primary) { save() }
                }
            }
            if isSet {
                SettingsRow(
                    key: "Kept private on this Mac",
                    hint: status.isEmpty ? nil : status,
                    showDivider: modelsLine != nil
                ) {
                    BrutalistButton("Remove", kind: .ghost) { remove() }
                }
            } else if !status.isEmpty {
                SettingsRow(key: "Status", hint: status, showDivider: modelsLine != nil) { EmptyView() }
            }
            if let modelsLine {
                SettingsRow(key: "Popular models", hint: modelsLine, showDivider: false) { EmptyView() }
            }
        }
        .task { isSet = keychain.hasValue(account: account) }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !account.isEmpty else {
            status = "The field was empty — nothing saved."
            return
        }
        do {
            try keychain.save(account: account, value: trimmed)
            draft = ""  // don't leave the secret in the field
            isSet = true
            status = "Key saved ✓"
            NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func remove() {
        do {
            try keychain.delete(account: account)
            isSet = false
            draft = ""
            status = "Key removed."
            NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
        } catch {
            status = "Remove failed: \(error.localizedDescription)"
        }
    }
}
