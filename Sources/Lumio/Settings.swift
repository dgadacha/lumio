import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @AppStorage("downloadDir") private var downloadDir = ""
    @AppStorage("defaultHeight") private var defaultHeight = 1080
    @State private var rowsText = ""
    @State private var keyDraft = ""
    @State private var keySaved = APIKeyStore.hasKey
    @State private var keyMessage = ""

    var body: some View {
        PageScaffold(title: "Réglages") {
            card("Téléchargements") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dossier de destination").font(.system(size: 13.5, weight: .semibold))
                        Text(Paths.downloads.path).font(.system(size: 12)).foregroundStyle(Theme.dim).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choisir…") { chooseFolder() }
                    Button("Ouvrir") {
                        try? FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.downloads)
                    }
                }
                Divider().overlay(Color.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 9) {
                    Text("Résolution proposée par défaut").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach([2160, 1440, 1080, 720, 480], id: \.self) { height in
                            Chip(label: "\(height)p", detail: VideoDetail.heightTag(height), selected: defaultHeight == height) {
                                defaultHeight = height
                            }
                        }
                    }
                }
            }

            card("Moteur de téléchargement") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.engine.version.map { "yt-dlp \($0)" } ?? "Non installé")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(state.engineLog.isEmpty
                             ? (state.engine.managed ? "Copie privée gérée par Lumio" : (state.engine.path ?? "Aucun moteur trouvé"))
                             : state.engineLog)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                    Spacer()
                    if state.engineBusy { ProgressView().controlSize(.small) }
                    Button(state.engine.managed ? "Mettre à jour" : "Installer la dernière version") { state.updateEngine() }
                        .disabled(state.engineBusy)
                }
                Text("Lumio installe sa propre copie de yt-dlp dans son dossier de données, sans toucher au reste du système. ffmpeg doit être présent (Homebrew).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            card("Suggestions par Claude") {
                Toggle(isOn: $state.aiEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rangées « Pour vous » sur l'accueil").font(.system(size: 13.5, weight: .semibold))
                        Text("Claude propose trois rangées d'après votre bibliothèque et vos recherches.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                Divider().overlay(Color.white.opacity(0.1))
                HStack(spacing: 8) {
                    SecureField(keySaved ? "Clé enregistrée dans le Trousseau" : "Clé API Anthropic (sk-ant-…)", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Enregistrer") {
                        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        keySaved = APIKeyStore.save(key)
                        keyMessage = keySaved ? "Clé enregistrée dans le Trousseau." : "Impossible d'écrire dans le Trousseau."
                        keyDraft = ""
                        if keySaved { Task { await state.refreshSuggestions(force: true) } }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keySaved {
                        Button("Supprimer") {
                            APIKeyStore.delete()
                            state.clearSuggestions()
                            keySaved = APIKeyStore.hasKey
                            keyMessage = "Clé supprimée."
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Actualiser les suggestions") { Task { await state.refreshSuggestions(force: true) } }
                        .disabled(!state.aiEnabled || !keySaved || state.aiBusy)
                    if state.aiBusy { ProgressView().controlSize(.small) }
                    Text(state.aiBusy ? "Claude réfléchit…" : (state.aiError ?? keyMessage))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                }
                Text("Désactivé par défaut. Une fois activé, les titres et chaînes de votre bibliothèque, votre avancement et vos recherches récentes sont envoyés à l'API d'Anthropic (modèle \(ClaudeClient.model)), facturée sur votre clé. Lumio ne rappelle l'API que si votre historique change, au plus une fois par heure. Clé à créer sur console.anthropic.com.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            card("Rangées de l'accueil") {
                Text("Une rangée par ligne : Titre | recherche (ou lien de playlist ou de chaîne).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                TextEditor(text: $rowsText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 150)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Enregistrer et recharger") {
                        UserDefaults.standard.set(rowsText, forKey: "homeRows")
                        state.tab = .home
                        Task { await state.loadHome(force: true) }
                    }
                    Button("Rétablir par défaut") {
                        rowsText = AppState.defaultRows
                    }
                }
            }
        }
        .onAppear { rowsText = state.rowsConfig }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Paths.downloads
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .bold))
            content()
        }
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
