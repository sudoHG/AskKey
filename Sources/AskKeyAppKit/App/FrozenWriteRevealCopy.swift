enum FrozenWriteRevealCopy {
    /// A create has no previous value, so only the value to save is shown.
    static func content(before: String, after: String) -> String {
        guard !before.isEmpty else { return after }
        return appLocalized("Before") + "\n" + before
            + "\n\n" + appLocalized("After") + "\n" + after
    }
}
