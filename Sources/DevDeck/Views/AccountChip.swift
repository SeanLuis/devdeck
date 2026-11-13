import DevDeckCore
import SwiftUI

/// The Claude Code account in use, at the top of every page: who, how full, and a menu to move to another one.
struct AccountChip: View {
    @Environment(AppModel.self) private var model
    @State private var pending: AgentAccount?

    var body: some View {
        let accounts = model.accounts.accounts(of: "Claude Code")
        if let active = accounts.first(where: \.active) {
            let window = active.windows.first { $0.name == "5 h" } ?? active.windows.first
            Menu {
                Section("Claude Code") {
                    ForEach(accounts) { account in
                        Button { if !account.active { pending = account } } label: {
                            Text(title(account) + (account.windows.isEmpty ? "" : "  ·  " + usage(account)))
                            if account.active { Image(systemName: "checkmark") }
                        }
                        .disabled(!account.active && !switchable(account))
                    }
                }
                Divider()
                Button(L("Ver cuentas y límites")) { UserDefaults.standard.set("accounts", forKey: "agentsTab"); model.selectedSection = .agents }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(window.map { Theme.level($0.percent / 100) } ?? Theme.success).frame(width: 6, height: 6)
                    Text(title(active)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 190)
                    if let window {
                        Text("\(Int(window.percent.rounded()))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Theme.ink(0.05)))
                .overlay(Capsule().strokeBorder(Theme.ink(0.09)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Cuenta de Claude Code en uso: %@", active.email))
            .confirmationDialog(L("¿Cambiar %@ a %@?", "Claude Code", pending?.email ?? ""), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button(L("Cambiar de cuenta")) {
                    if let account = pending { Task { await model.switchClaudeAccount(account) } }
                    pending = nil
                }
            } message: {
                Text(L("Las sesiones nuevas usarán esta cuenta. Las que ya están abiertas pueden necesitar reiniciarse."))
            }
        }
    }

    private func title(_ account: AgentAccount) -> String { account.alias ?? account.email }

    private func usage(_ account: AgentAccount) -> String {
        account.windows.prefix(2).map { "\(L($0.name)) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
    }

    private func switchable(_ account: AgentAccount) -> Bool {
        model.switchingAccount == nil && account.number != nil && (account.vaultID != nil || model.accounts.switcherPath != nil)
    }
}
