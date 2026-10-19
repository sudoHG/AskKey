@MainActor
final class LibraryInstanceActivation {
    private var activate: (() -> Void)?
    private var pending = false

    func request() {
        if let activate { activate() }
        else { pending = true }
    }

    func install(_ activate: @escaping () -> Void) {
        self.activate = activate
        if pending {
            pending = false
            activate()
        }
    }
}
