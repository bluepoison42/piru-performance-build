import Foundation

/// One record of a delimited text file: its cells and its row number as a
/// spreadsheet would show it (1-based, blank rows counted).
nonisolated struct DelimitedRecord: Equatable, Sendable {
    let row: Int
    let cells: [String]

    /// Whether every cell is empty or whitespace.
    var isBlank: Bool {
        cells.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The cell at `index`, trimmed, or an empty string past the end of a short row.
    func cell(_ index: Int) -> String {
        guard index >= 0, index < cells.count else { return "" }
        return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A CSV, semicolon-separated or tab-separated file read into records.
nonisolated struct DelimitedTable: Equatable, Sendable {
    let delimiter: Unicode.Scalar
    /// Every non-blank record, in file order.
    let records: [DelimitedRecord]

    /// The widest record's cell count.
    var columnCount: Int {
        records.map(\.cells.count).max() ?? 0
    }
}

/// Reads and writes delimited text per RFC 4180: quoted fields may hold the
/// delimiter, line breaks and doubled quotes; records end in CRLF, LF or CR.
nonisolated enum DelimitedText {
    /// The delimiters detection chooses between, in tie-break order.
    static let candidates: [Unicode.Scalar] = ["\t", ";", ","]

    /// Decodes, detects the delimiter and parses `data`, dropping blank records.
    /// `nil` when the bytes are not text in any encoding tried.
    static func read(_ data: Data) -> DelimitedTable? {
        guard let text = decode(data) else { return nil }
        return read(text)
    }

    static func read(_ text: String) -> DelimitedTable {
        let delimiter = detectDelimiter(in: text)
        let records = parse(text, delimiter: delimiter).filter { !$0.isBlank }
        return DelimitedTable(delimiter: delimiter, records: records)
    }

    // MARK: - Decoding

    /// The file as text: UTF-8 or UTF-16 by byte-order mark, UTF-16 by its zero
    /// bytes when the mark is missing (Excel's "Unicode Text" export), then UTF-8,
    /// then Latin-1, which decodes any byte sequence.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if looksLikeUTF16LittleEndian(data) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// ASCII text in UTF-16LE puts a zero in every odd byte.
    private static func looksLikeUTF16LittleEndian(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(64))
        guard sample.count >= 4, sample.count.isMultiple(of: 2) else { return false }
        let oddZeros = stride(from: 1, to: sample.count, by: 2).count { sample[$0] == 0 }
        let evenZeros = stride(from: 0, to: sample.count, by: 2).count { sample[$0] == 0 }
        return oddZeros * 4 >= sample.count && evenZeros == 0
    }

    // MARK: - Delimiter detection

    /// The delimiter that splits the first records into the most consistent
    /// number of cells. Each candidate parses the same prefix with quoting
    /// respected; the score is the share of records whose cell count matches
    /// the most common count, which must be at least two. A tie goes to the
    /// candidate giving more cells, so a semicolon sheet whose amounts carry
    /// decimal commas ("0,75") is not read as comma-separated.
    static func detectDelimiter(in text: String) -> Unicode.Scalar {
        var best: (delimiter: Unicode.Scalar, score: Double, width: Int) = (",", -1, 0)
        for candidate in candidates {
            let records = parse(text, delimiter: candidate, limit: 50).filter { !$0.isBlank }
            guard !records.isEmpty else { continue }
            var counts: [Int: Int] = [:]
            for record in records {
                counts[record.cells.count, default: 0] += 1
            }
            guard let (width, matching) = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), width >= 2 else {
                continue
            }
            let score = Double(matching) / Double(records.count)
            if score > best.score + 1e-9 || (abs(score - best.score) < 1e-9 && width > best.width) {
                best = (candidate, score, width)
            }
        }
        return best.delimiter
    }

    // MARK: - Parsing

    /// Splits `text` into records. `limit` stops after that many records.
    static func parse(_ text: String, delimiter: Unicode.Scalar, limit: Int = .max) -> [DelimitedRecord] {
        var records: [DelimitedRecord] = []
        var cells: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false
        var row = 1
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        func endField() {
            cells.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }
        func endRecord() {
            endField()
            records.append(DelimitedRecord(row: row, cells: cells))
            cells = []
            row += 1
        }

        while records.count < limit {
            guard let scalar = pending ?? scalars.next() else { break }
            pending = nil
            if inQuotes {
                if scalar == "\"" {
                    let next = scalars.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    field.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true
                fieldStarted = true
            case delimiter:
                endField()
            case "\r":
                let next = scalars.next()
                if next != "\n" { pending = next }
                endRecord()
            case "\n":
                endRecord()
            case "\u{FEFF}" where records.isEmpty && cells.isEmpty && field.isEmpty:
                continue
            default:
                field.append(scalar)
                fieldStarted = true
            }
        }
        if records.count < limit, fieldStarted || !field.isEmpty || !cells.isEmpty {
            endRecord()
        }
        return records
    }

    // MARK: - Writing

    /// Rows joined by `delimiter`, quoting any field that needs it, with CRLF
    /// line endings.
    static func write(_ rows: [[String]], delimiter: Unicode.Scalar = ",") -> String {
        rows.map { row in
            row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }
        .joined(separator: "\r\n") + "\r\n"
    }

    /// The characters that make Excel, Sheets and Numbers read a cell as a formula.
    private static let formulaLeads: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Free text made safe to open in a spreadsheet: a cell that would start a
    /// formula gets a leading `'`, which spreadsheets read as "this is text".
    /// Only for text the person typed; numbers Piru writes itself stay bare.
    ///
    /// Text that already looks guarded ("'=1+1" as typed) gets one more `'`,
    /// so ``restoringFormula(_:)``, which removes exactly one, gives it back
    /// unchanged.
    static func neutralizingFormula(_ text: String) -> String {
        looksGuarded(Substring(text)) ? "'" + text : text
    }

    /// Undoes ``neutralizingFormula(_:)``: drops one leading `'` when what
    /// follows it would have been guarded, so "'s avonds" keeps its apostrophe.
    static func restoringFormula(_ text: String) -> String {
        guard text.hasPrefix("'"), looksGuarded(text.dropFirst()) else { return text }
        return String(text.dropFirst())
    }

    /// Opens with a formula character, after any number of `'`.
    private static func looksGuarded(_ text: Substring) -> Bool {
        guard let first = text.first(where: { $0 != "'" }) else { return false }
        return formulaLeads.contains(first)
    }

    /// `field` quoted when it holds the delimiter, a quote, a line break, or
    /// leading/trailing spaces, with inner quotes doubled.
    static func escape(_ field: String, delimiter: Unicode.Scalar) -> String {
        let needsQuotes = field.unicodeScalars.contains { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || field.hasPrefix(" ") || field.hasSuffix(" ")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
