import Observation
import AskKeyVault

/// Shared with navigation so a click reads the current form/confirmation state
/// synchronously, rather than an asynchronously published summary of that state.
@Observable
@MainActor
final class ManagementInteractionState {
    var searchText = ""
    var deletingCredential: ManagedTextCredential?
    var permanentlyDeletingCredentialID: String?
    var deletingGroupName: String?
    var showingNewGroup = false
    var newGroupName = ""

    var hasWorkInProgress: Bool {
        !searchText.isEmpty || deletingCredential != nil
            || permanentlyDeletingCredentialID != nil || deletingGroupName != nil
            || showingNewGroup || !newGroupName.isEmpty
    }

    func reset() {
        searchText = ""
        deletingCredential = nil
        permanentlyDeletingCredentialID = nil
        deletingGroupName = nil
        showingNewGroup = false
        newGroupName = ""
    }
}
