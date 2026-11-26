import AlbumWinnowApple
import SwiftUI

struct SavedProtectionSettings: View {
    let model: ReviewModel
    @State private var unlocking: AssetID?
    @State private var clearingInvalid = false

    var body: some View {
        Section(L10n.text("app_saved_protection")) {
            ForEach(model.savedLocks.sorted { $0.source == $1.source ? $0.item < $1.item : $0.source < $1.source }, id: \.self) { id in
                VStack(alignment: .leading, spacing: 6) {
                    Label(id.item, systemImage: "lock.fill").textSelection(.enabled)
                    Text(model.sourceLabel(id.source)).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("app_remove_saved_lock"), role: .destructive) { unlocking = id }
                        .buttonStyle(.borderless)
                }
            }
            Text(L10n.text("app_saved_protection_explanation")).font(.caption).foregroundStyle(.secondary)
            if model.invalidDecisionCount > 0 {
                Button(L10n.text("app_remove_invalid_decisions", Int64(model.invalidDecisionCount)), role: .destructive) { clearingInvalid = true }
            }
        }
        .disabled(!model.canEditSources || !model.protectionAvailable)
        .confirmationDialog(unlocking != nil ? L10n.text("app_remove_saved_lock") : L10n.text("app_remove_invalid_decisions", Int64(model.invalidDecisionCount)), isPresented: Binding(
            get: { unlocking != nil || clearingInvalid },
            set: { if !$0 { unlocking = nil; clearingInvalid = false } }
        ), titleVisibility: .visible) {
            if let id = unlocking {
                Button(L10n.text("app_remove_saved_lock"), role: .destructive) { model.removeSavedLock(id) }
            } else {
                Button(L10n.text("app_remove_invalid_decisions", Int64(model.invalidDecisionCount)), role: .destructive) { model.removeInvalidDecisions() }
            }
        } message: {
            Text(unlocking.map { L10n.text("app_saved_lock_confirmation", $0.item) } ?? L10n.text("app_invalid_decisions_confirmation"))
        }
    }
}
