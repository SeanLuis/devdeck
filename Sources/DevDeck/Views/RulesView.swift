import DevDeckCore
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Rule?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroHeader(section: .rules, title: L("Límites y alertas"), subtitle: L("Reglas que vigilan RAM, swap, disco y procesos; avisan, reinician, cierran o llaman a la IA")) {
                    Button {
                        editing = Rule(name: L("Nueva regla"), metric: .groupMemoryMB, threshold: 4096)
                    } label: { Label(L("Nueva regla"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                }
                Panel {
                    VStack(spacing: 0) {
                        ForEach($model.rules) { $rule in
                            HStack(spacing: 12) {
                                Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                                    .onChange(of: rule.enabled) { model.saveRules() }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(rule.name)).font(.callout.weight(.medium))
                                    Text(rule.summary).font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                Button(L("Editar")) { editing = rule }.buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    model.rules.removeAll { $0.id == rule.id }
                                    model.saveRules()
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                        HStack {
                            Spacer()
                            Button(L("Restaurar reglas por defecto")) {
                                model.rules = Rule.defaults
                                model.saveRules()
                            }
                            .buttonStyle(.link)
                        }
                        .padding(.top, 8)
                    }
                    .padding(6)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L("Historial")).font(.headline)
                            Spacer()
                            Button(L("Probar notificación")) { model.notify(title: L("Prueba"), body: L("Así se ve un aviso de DevDeck"), severity: .info, force: true) }
                            Button(L("Borrar historial"), role: .destructive) { model.clearAlerts() }
                        }
                        AlertsList(limit: 100)
                    }
                    .padding(6)
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                if let index = model.rules.firstIndex(where: { $0.id == updated.id }) {
                    model.rules[index] = updated
                } else {
                    model.rules.append(updated)
                }
                model.saveRules()
            }
        }
    }
}

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let onSave: (Rule) -> Void

    var body: some View {
        Form {
            TextField(L("Nombre"), text: $rule.name)
            Picker(L("Métrica"), selection: $rule.metric) {
                ForEach(RuleMetric.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: rule.metric) { rule.comparator = rule.metric.defaultComparator }
            if rule.metric.isGroupMetric {
                Picker(L("Aplicar a"), selection: $rule.targetGroupID) {
                    Text(L("Cualquier proyecto")).tag(String?.none)
                    ForEach(model.snapshot.groups.filter { $0.kind != .system }) { g in
                        Text("\(g.name) (\(g.kind.title))").tag(String?.some(g.id))
                    }
                }
            }
            Picker(L("Condición"), selection: $rule.comparator) {
                Text(L("mayor que")).tag(RuleComparator.above)
                Text(L("menor que")).tag(RuleComparator.below)
            }
            TextField(L("Umbral"), value: $rule.threshold, format: .number)
            TextField(L("Sostenido durante (segundos)"), value: $rule.sustainSeconds, format: .number)
            Picker(L("Acción"), selection: $rule.action) {
                ForEach(RuleAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField(L("No repetir antes de (segundos)"), value: $rule.cooldownSeconds, format: .number)
            Text(rule.summary).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Cancelar")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Guardar")) { onSave(rule); dismiss() }
            }
        }
        .padding()
    }
}
