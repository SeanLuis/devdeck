import AppKit
import DevDeckCore
import SwiftUI

@MainActor
extension AppModel {
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Looks for a newer release. It only ever tells the user; nothing is downloaded or installed without a click.
    func checkForUpdates(manual: Bool = false) async {
        guard !updateChecking, !demo else { return }
        updateChecking = true
        defer { updateChecking = false }
        updateError = nil
        do {
            let latest = try await Updates.fetchLatest()
            lastUpdateCheck = Date()
            if let latest, Updates.isNewer(latest.version, than: appVersion) {
                let isNews = availableUpdate?.version != latest.version
                availableUpdate = latest
                if settings.skippedVersion == latest.version && !manual { return }
                if manual { showUpdate = true }
                else if isNews { presentAlert(title: L("DevDeck %@ disponible", latest.version), body: L("Ábrela desde la barra lateral para ver qué trae y actualizar."), severity: .info) }
            } else {
                availableUpdate = nil
                if manual { show(L("Ya tienes la última versión (%@)", appVersion)) }
            }
        } catch {
            if manual { updateError = L("No se pudo comprobar: %@", error.localizedDescription) }
        }
    }

    /// The update the user should be told about (not the one they chose to skip).
    var pendingUpdate: AppRelease? {
        guard let update = availableUpdate, settings.skippedVersion != update.version else { return nil }
        return update
    }

    func skipUpdate(_ release: AppRelease) {
        settings.skippedVersion = release.version
        saveSettings()
        showUpdate = false
    }

    /// Downloads, verifies and installs the update, then relaunches. Runs only from the user's click.
    func installUpdate(_ release: AppRelease) async {
        guard !updateInstalling else { return }
        guard isBundled, release.downloadURL != nil else {
            if let url = URL(string: release.pageURL) { NSWorkspace.shared.open(url) }
            return
        }
        updateInstalling = true
        updateError = nil
        updateStage = nil
        let path = Bundle.main.bundlePath
        do {
            try await Updates.install(release, replacing: path) { stage in
                await MainActor.run {
                    switch stage {
                    case .downloading: self.updateStage = L("Descargando…")
                    case .verifying: self.updateStage = L("Comprobando la firma…")
                    case .installing: self.updateStage = L("Instalando…")
                    }
                }
            }
        } catch {
            updateInstalling = false
            updateStage = nil
            updateError = error.localizedDescription
            return
        }
        updateStage = L("Reiniciando…")
        saveConversation()
        _ = resumePaused()
        // The new copy opens once this one has really ended: a fixed "sleep 1" opened the old instance again
        // when quitting took longer, and DevDeck was left running the old version.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "for i in $(seq 1 100); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.2; done; kill -9 \"$1\" 2>/dev/null; sleep 0.3; /usr/bin/open \"$0\"",
                          path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        showUpdate = false
        // Quit once the sheet is gone; if something still holds the quit back, end the process anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppPresence.quit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    }
}

/// Small card in the sidebar while a newer version exists.
struct UpdateCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.pendingUpdate {
            Button { model.showUpdate = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.link)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Actualización disponible")).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                        Text(L("Versión %@", update.version)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(cornerRadius: 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// What is new in the release, and the decision: update now, later, or skip this version.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppGlyph(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("DevDeck %@ disponible", release.version)).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            Text(L("Novedades").uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(Theme.tertiaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in ReleaseNoteLine(text: line) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 230)
            .background(Theme.ink(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let error = model.updateError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Se descarga de GitHub, se comprueba que esté firmada y notarizada por Apple, se instala y DevDeck se reinicia."))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Omitir esta versión")) { model.skipUpdate(release) }.buttonStyle(.bordered)
                Button(L("Ver en GitHub")) { if let url = URL(string: release.pageURL) { NSWorkspace.shared.open(url) } }.buttonStyle(.bordered)
                Spacer()
                Button(L("Más tarde")) { model.showUpdate = false }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.installUpdate(release) }
                } label: {
                    if model.updateInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.updateStage ?? L("Preparando…"))
                        }
                    } else {
                        Text(L("Actualizar y reiniciar"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.updateInstalling)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.background)
        .appAppearance(model.settings.appearance)
    }

    private var subtitle: String {
        var parts = [L("Tienes la %@", model.appVersion)]
        if let date = release.publishedAt { parts.append(L("publicada %@", relative(date))) }
        return parts.joined(separator: " · ")
    }

    private var lines: [String] {
        let all = release.notes.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return all.isEmpty ? [L("Esta versión no trae notas.")] : all
    }
}

/// One line of release notes: headings, bullets and inline markdown, without a full markdown renderer.
struct ReleaseNoteLine: View {
    let text: String

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            Text(trimmed.drop { $0 == "#" || $0 == " " }).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(Theme.tertiaryText)
                Text(inline(String(trimmed.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
        } else {
            Text(inline(trimmed)).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
