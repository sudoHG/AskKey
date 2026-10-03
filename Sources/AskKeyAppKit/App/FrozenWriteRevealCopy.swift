enum FrozenWriteRevealCopy {
    static func content(before: String, after: String) -> String {
        appLocalized("Before") + "\n" + before
            + "\n\n" + appLocalized("After") + "\n" + after
    }
}
