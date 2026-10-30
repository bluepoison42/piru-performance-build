extension String {
    nonisolated var substanceSearchKey: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
