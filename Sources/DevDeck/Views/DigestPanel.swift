import AppKit
import DevDeckCore
import SwiftUI

extension AppModel {
    /// Builds the digest of a day (0 = today, 1 = yesterday…).
    func loadDigest(daysAgo: Int) async {
        let day = AgentUsageReport.dayString(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
        if demo {
            let code = NSHomeDirectory() + "/Code"
            let commits = ["\(code)/storefront": [DigestCommit(hash: "a41c9e2", subject: "Round coupon totals to the cent"),
                                                  DigestCommit(hash: "7be03d1", subject: "Move checkout tests to Playwright")],
                           "\(code)/billing-api": [DigestCommit(hash: "c90f1aa", subject: "Add invoice PDF endpoint")]]
            await loadSessions()
            digest = DailyDigests.build(day: day, usage: agentUsage, prices: prices, sessions: sessionLibrary, commits: daysAgo == 0 ? commits : [:])
            return
        }
        digestLoading = true
        if sessionLibrary.isEmpty { await loadSessions() }
        let (env, table, usage, library) = (loginEnv, prices, agentUsage, sessionLibrary)
        digest = await Task.detached(priority: .utility) {
            await DailyDigests.load(day: day, env: env, prices: table, usage: usage, sessions: library)
        }.value
        digestLoading = false
    }
}

/// The day at a glance, per project: what the agents were asked, what it cost and what got committed.
struct DigestPanel: View {
    @Environment(AppModel.self) private var model
    @State private var daysAgo = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $daysAgo) {
                    Text(L("Hoy")).tag(0)
                    Text(L("Ayer")).tag(1)
                    Text(L("Anteayer")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.digestLoading { ProgressView().controlSize(.small) }
                if let digest = model.digest {
                    Text(headline(digest)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button {
                    guard let digest = model.digest else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DailyDigests.markdown(digest), forType: .string)
                    model.show(L("Resumen copiado"))
                } label: { Label(L("Copiar"), systemImage: "doc.on.doc") }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.digest?.projects.isEmpty ?? true)
                .help(L("Copia el resumen como texto, para un parte diario"))
            }
            if let digest = model.digest {
                ForEach(digest.projects) { project in
                    Panel(project.name) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(facts(project)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                            ForEach(project.sessions.prefix(8), id: \.self) { title in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(Theme.tertiaryText).frame(width: 14)
                                    Text(title).font(.system(size: 12)).lineLimit(1)
                                }
                            }
                            ForEach(project.commits.prefix(12), id: \.self) { commit in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.tertiaryText).frame(width: 14)
                                    Text(commit.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
                                    Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                                }
                            }
                            let more = max(0, project.sessions.count - 8) + max(0, project.commits.count - 12)
                            if more > 0 { Text(L("y %d más", more)).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText) }
                        }
                    }
                }
                if digest.projects.isEmpty, !model.digestLoading {
                    Text(L("Sin trabajo de agentes ese día")).font(.caption).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .task(id: daysAgo) { await model.loadDigest(daysAgo: daysAgo) }
    }

    private func headline(_ digest: DailyDigest) -> String {
        var parts = [L("%@ tokens", compact(digest.tokens.billable))]
        if let dollars = digest.dollars { parts.append(costText(dollars)) }
        parts.append(plural(digest.sessionCount, "%d sesión", "%d sesiones"))
        parts.append(plural(digest.commitCount, "%d commit", "%d commits"))
        return parts.joined(separator: " · ")
    }

    private func facts(_ project: DigestProject) -> String {
        var parts: [String] = []
        if project.tokens.billable > 0 { parts.append(L("%@ tokens", compact(project.tokens.billable))) }
        if let dollars = project.dollars { parts.append(costText(dollars)) }
        if !project.agents.isEmpty { parts.append(project.agents.joined(separator: ", ")) }
        parts.append(Fmt.tilde(project.folder))
        return parts.joined(separator: " · ")
    }
}
