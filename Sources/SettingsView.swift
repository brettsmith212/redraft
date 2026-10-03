import SwiftUI

struct SettingsView: View {
    @AppStorage("aiProvider") private var provider = AIProvider.chatGPT.rawValue
    @AppStorage("ai.anthropic.model") private var anthropicModel = ""
    @AppStorage("ai.anthropic.effort") private var anthropicEffort = "low"
    @AppStorage("ai.openAI.model") private var openAIModel = ""
    @AppStorage("ai.openAI.effort") private var openAIEffort = "low"
    @AppStorage("ai.chatGPT.model") private var chatgptModel = ""
    @AppStorage("ai.chatGPT.effort") private var chatgptEffort = AISettings.defaultEffort(.chatGPT)
    @ObservedObject private var chatGPT = ChatGPTAuth.shared
    @ObservedObject private var openAIModels = OpenAIModels.shared
    @ObservedObject private var anthropicModels = AnthropicModels.shared
    @AppStorage("ai.anthropic.workspace") private var anthropicWorkspace = ""
    @AppStorage("soundsEnabled") private var soundsEnabled = true
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system.rawValue
    @AppStorage("hideMarkdownSyntax") private var hideMarkdown = true
    @AppStorage("shortcutStyle") private var shortcutStyle = AppShortcut.Style.command.rawValue
    @AppStorage("vimEnabled") private var vimEnabled = false
    @AppStorage("vimScreenLines") private var vimScreenLines = true
    @AppStorage("vimMappings") private var vimMappings = VimEngine.defaultMappings
    /// The open tab; set to "ai" by links that lead here from AI setup.
    @AppStorage(SettingsView.tabKey) private var selectedTab = "ai"
    static let tabKey = "settingsTab"

    /// Opens Settings on the AI tab next time (call just before a SettingsLink fires).
    static func showAITab() { UserDefaults.standard.set("ai", forKey: tabKey) }

    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var status: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            tab {
                Section("Connection") {
                Picker("Connect with", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pointingHandOnHover()

                switch AIProvider(rawValue: provider) ?? .chatGPT {
                case .anthropic:
                    SecureField("API key", text: $anthropicKey, prompt: Text("sk-ant-…"))
                    saveRow {
                        APIKeyStore.anthropic.save(anthropicKey)
                        Task { await anthropicModels.load() }
                    }
                    caption("Stored in your Keychain. Falls back to ANTHROPIC_API_KEY.")
                    anthropicModelSection
                case .openAI:
                    SecureField("API key", text: $openAIKey, prompt: Text("sk-…"))
                    saveRow {
                        APIKeyStore.openAI.save(openAIKey)
                        Task { await openAIModels.load() }
                    }
                    caption("Stored in your Keychain. Falls back to OPENAI_API_KEY.")
                    openAIModelSection
                case .chatGPT:
                    chatGPTSection
                }
                }
            }
            .tabItem { Label("AI", systemImage: "sparkles") }
            .tag("ai")

            tab {
                Section("Appearance") {
                Picker("Light or dark", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .pointingHandOnHover()
                .onChange(of: appearance) { AppearanceSetting.apply() }
                Text("System follows your Mac's Light or Dark setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Writing") {
                Toggle("Hide Markdown symbols outside the line you're editing", isOn: $hideMarkdown)
                .pointingHandOnHover()
                Toggle("Play sounds when cycling alternatives", isOn: $soundsEnabled)
                .pointingHandOnHover()
                }
                ShellCommandSection()
                UpdatesSection()
            }
            .tabItem { Label("Editor", systemImage: "textformat") }
            .tag("editor")

            tab {
                Section("Shortcuts") {
                Picker("Modifier keys", selection: $shortcutStyle) {
                    ForEach(AppShortcut.Style.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pointingHandOnHover()
                caption(shortcutStyle == AppShortcut.Style.control.rawValue
                    ? "Redraft's shortcuts use Control + Shift + a letter (⌃⇧A alternatives, ⌃⇧G ghost…), leaving plain Control keys for Vim and text editing. Standard Mac shortcuts like ⌘S stay the same."
                    : "Redraft's shortcuts use Option + Command (⌥⌘A alternatives, ⌥⌘L lab, ⌥⌘G ghost…).")
                }
                Section("Vim") {
                Toggle("Vim mode", isOn: $vimEnabled)
                .pointingHandOnHover()
                if vimEnabled {
                    Toggle("Line motions follow wrapped lines", isOn: $vimScreenLines)
                .pointingHandOnHover()
                    caption(vimScreenLines
                        ? "j k 0 ^ $ I A D C dd cc yy V act on the line as you see it. o and J act on the whole paragraph."
                        : "Strict Vim: a line is a whole paragraph. Use gj gk g0 g^ g$ for wrapped lines.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key mappings")
                        TextEditor(text: $vimMappings)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        let errors = VimMappings.parse(vimMappings).errors
                        if errors.isEmpty {
                            caption("One per line, vimrc style: inoremap jk <Esc> · nnoremap Y y$ · vnoremap … Supports map, noremap, nmap, nnoremap, imap, inoremap, vmap, vnoremap, xmap. Lines starting with \" are comments.")
                        } else {
                            ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
                }
            }
            .tabItem { Label("Keyboard", systemImage: "keyboard") }
            .tag("keyboard")
        }
        .frame(width: 540)
        .task {
            if openAIModels.models.isEmpty, APIKeyStore.openAI.storedKey() != nil { await openAIModels.load() }
            if anthropicModels.models.isEmpty, APIKeyStore.anthropic.storedKey() != nil { await anthropicModels.load() }
            await chatGPT.loadIfNeeded()
            if chatGPT.isConnected && chatGPT.models.isEmpty { await chatGPT.loadModels() }
        }
        .onAppear {
            Self.migrateLegacyModels()
            anthropicKey = APIKeyStore.anthropic.storedKey() ?? ""
            openAIKey = APIKeyStore.openAI.storedKey() ?? ""
        }
        .onChange(of: provider) { _, _ in status = nil }
    }

    /// One Settings tab: a grouped form that scrolls if it runs long, so the
    /// window always fits the screen.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(width: 540, height: 470)
    }

    @ViewBuilder
    private var chatGPTSection: some View {
        if let connection = chatGPT.connection {
            LabeledContent("Connected as") {
                Text(connection.email ?? connection.name ?? "ChatGPT account")
                    .textSelection(.enabled)
            }
            Picker("Model", selection: $chatgptModel) {
                Text(chatGPT.defaultModel.map { "Default (\($0.displayName))" } ?? "Default").tag("")
                ForEach(chatGPT.models) { Text($0.displayName).tag($0.slug) }
                if !chatgptModel.isEmpty && !chatGPT.models.contains(where: { $0.slug == chatgptModel }) {
                    Text(chatgptModel).tag(chatgptModel)
                }
            }
            .pointingHandOnHover()
            chatGPTReasoningPicker
            HStack {
                Button("Refresh Models") { Task { await chatGPT.loadModels() } }
                .pointingHandOnHover()
                Spacer()
                Button("Disconnect", role: .destructive) { chatGPT.signOut() }
                .pointingHandOnHover()
            }
            UsingChatGPTPlanLabel()
        } else if chatGPT.signingIn {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…")
                Spacer()
                Button("Cancel") { chatGPT.cancelSignIn() }
                .pointingHandOnHover()
            }
        } else {
            HStack {
                Spacer()
                ContinueWithChatGPTButton { chatGPT.signIn() }
                Spacer()
            }
            caption("Complete eligible AI requests with usage included in your ChatGPT plan. Opens your browser to sign in; Redraft keeps the connection in your Keychain and never sees your password.")
        }
        if let error = chatGPT.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    /// Claude models this key can use (from Anthropic), with a refresh, and the
    /// workspace field for keys that need one.
    @ViewBuilder
    private var anthropicModelSection: some View {
        if anthropicModels.needsWorkspace || !anthropicWorkspace.isEmpty {
            TextField("Workspace ID", text: $anthropicWorkspace, prompt: Text("wrkspc_…"))
                .onSubmit { Task { await anthropicModels.load() } }
            caption("Only needed for keys that aren't tied to a workspace. Find it in the Claude Console under Settings → Workspaces.")
        }
        Picker("Model", selection: $anthropicModel) {
            Text("Default (Claude Sonnet 5.5)").tag("")
            if anthropicModels.models.isEmpty {
                ForEach(AIClient.anthropicModels, id: \.id) { Text($0.name).tag($0.id) }
            } else {
                ForEach(anthropicModels.models) { Text($0.name).tag($0.id) }
            }
            let known = anthropicModels.models.map(\.id) + AIClient.anthropicModels.map(\.id)
            if !anthropicModel.isEmpty && !known.contains(anthropicModel) {
                Text(anthropicModel).tag(anthropicModel)
            }
        }
        .pointingHandOnHover()
        let levels = anthropicModels.levels(for: anthropicModel.isEmpty ? AISettings.defaultAnthropicModel : anthropicModel)
        if levels.isEmpty {
            reasoningPicker(.anthropic, $anthropicEffort)
        } else {
            Picker("Reasoning", selection: $anthropicEffort) {
                ForEach(levels, id: \.self) { Text(AISettings.title(forEffort: $0)).tag($0) }
            }
            .pointingHandOnHover()
            .onChange(of: anthropicModel) { _, _ in
                // A model without the chosen level falls back to the gentlest it has.
                let now = anthropicModels.levels(for: anthropicModel.isEmpty ? AISettings.defaultAnthropicModel : anthropicModel)
                if !now.isEmpty, !now.contains(anthropicEffort) { anthropicEffort = now.first ?? "low" }
            }
            caption("Levels this model supports. Used for alternatives, ?? and the Lab. Lower is faster; raise it if Lab results feel shallow.")
        }
        HStack(spacing: 8) {
            Button("Refresh Models") { Task { await anthropicModels.load() } }
                .pointingHandOnHover()
                .disabled(anthropicModels.loading || APIKeyStore.anthropic.key == nil)
            if anthropicModels.loading { ProgressView().controlSize(.small) }
            Spacer()
            if !anthropicModels.models.isEmpty {
                Text("\(anthropicModels.models.count) models").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = anthropicModels.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    /// Models this key can use (from OpenAI), with a refresh.
    @ViewBuilder
    private var openAIModelSection: some View {
        Picker("Model", selection: $openAIModel) {
            Text("Default (\(openAIModels.recommended ?? AIClient.defaultOpenAIModel))").tag("")
            ForEach(openAIModels.models) { Text($0.id).tag($0.id) }
            if !openAIModel.isEmpty && !openAIModels.models.contains(where: { $0.id == openAIModel }) {
                Text(openAIModel).tag(openAIModel)
            }
        }
        .pointingHandOnHover()
        let levels = openAIModels.levels(for: openAIModel.isEmpty ? (openAIModels.recommended ?? AIClient.defaultOpenAIModel) : openAIModel)
        Picker("Reasoning", selection: $openAIEffort) {
            if levels.isEmpty {
                ForEach(AISettings.efforts(for: .openAI), id: \.value) { Text($0.title).tag($0.value) }
            } else {
                Text("Automatic").tag("")
                ForEach(levels, id: \.self) { Text(AISettings.title(forEffort: $0)).tag($0) }
            }
        }
        .pointingHandOnHover()
        HStack(spacing: 8) {
            Button("Refresh Models") { Task { await openAIModels.load() } }
                .pointingHandOnHover()
                .disabled(openAIModels.loading || APIKeyStore.openAI.key == nil)
            if openAIModels.loading { ProgressView().controlSize(.small) }
            Spacer()
            if !openAIModels.models.isEmpty {
                Text("\(openAIModels.models.count) models").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = openAIModels.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else {
            caption("Used for alternatives, ?? and the Lab. Lower reasoning is faster; if a model doesn't support a level, Redraft uses the nearest one it does.")
        }
    }

    /// The selected model's own reasoning levels, from the plan's catalog.
    @ViewBuilder
    private var chatGPTReasoningPicker: some View {
        let model = chatGPT.models.first { $0.slug == (chatgptModel.isEmpty ? chatGPT.defaultModel?.slug : chatgptModel) }
        let levels = model?.levels ?? []
        Picker("Reasoning", selection: $chatgptEffort) {
            Text(model?.defaultLevel.map { "Automatic (\(AISettings.title(forEffort: $0)))" } ?? "Automatic").tag("")
            if levels.isEmpty {
                ForEach(AISettings.efforts(for: .chatGPT).dropFirst(), id: \.value) { Text($0.title).tag($0.value) }
            } else {
                ForEach(levels, id: \.effort) { level in
                    Text(AISettings.title(forEffort: level.effort) + (level.effort == "ultra" ? " (slowest)" : "")).tag(level.effort)
                }
            }
        }
        .pointingHandOnHover()
        .onChange(of: chatgptModel) { _, _ in
            // A model that doesn't offer the chosen level falls back to its own default.
            let newModel = chatGPT.models.first { $0.slug == (chatgptModel.isEmpty ? chatGPT.defaultModel?.slug : chatgptModel) }
            if let newModel, !newModel.levels.isEmpty, !chatgptEffort.isEmpty,
               !newModel.levels.contains(where: { $0.effort == chatgptEffort }) {
                chatgptEffort = ""
            }
        }
        let description = levels.first { $0.effort == chatgptEffort }?.description
        caption((description.map { $0 + ". " } ?? "") + "Used for alternatives, ?? and the Lab. Lower is faster.")
    }

    /// One model and one reasoning level drive every AI feature.
    @ViewBuilder
    private func reasoningPicker(_ provider: AIProvider, _ selection: Binding<String>) -> some View {
        Picker("Reasoning", selection: selection) {
            ForEach(AISettings.efforts(for: provider), id: \.value) { Text($0.title).tag($0.value) }
        }
        .pointingHandOnHover()
        caption("Used for alternatives, ?? and the Lab. Lower is faster; raise it if Lab results feel shallow.")
    }

    private func saveRow(_ save: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).font(.caption) }
            Button("Save Key") {
                save()
                status = "Saved"
            }
            .pointingHandOnHover()
        }
    }

    /// Earlier versions stored one model under different keys.
    private static func migrateLegacyModels() {
        let defaults = UserDefaults.standard
        for (legacy, current) in [("chatgptModel", "ai.chatGPT.model"), ("aiModel", "ai.anthropic.model"), ("openAIModel", "ai.openAI.model")] {
            if let value = defaults.string(forKey: legacy), !value.isEmpty, (defaults.string(forKey: current) ?? "").isEmpty {
                defaults.set(value, forKey: current)
            }
            defaults.removeObject(forKey: legacy)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Install or remove the `redraft` terminal command.
private struct ShellCommandSection: View {
    @State private var installed = ShellCommand.installed

    var body: some View {
        Section("Shell command") {
            LabeledContent {
                if installed != nil {
                    Button("Remove") {
                        ShellCommand.uninstall()
                        installed = ShellCommand.installed
                    }
                    .pointingHandOnHover()
                } else {
                    Button("Install") {
                        ShellCommand.installWithAlert()
                        installed = ShellCommand.installed
                    }
                    .pointingHandOnHover()
                }
            } label: {
                Text("Open files from a terminal with `redraft file.md`")
                Text(installed.map { "Installed at " + $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
                     ?? "Not installed")
            }
        }
    }
}
