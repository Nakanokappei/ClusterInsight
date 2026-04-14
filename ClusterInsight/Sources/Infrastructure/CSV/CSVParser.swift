import Foundation

// Parses CSV files with support for BOM-prefixed UTF-8, quoted fields containing
// newlines and commas, and Japanese text. Designed for the phone transcript dataset.
struct CSVParser: Sendable {

    // Represents a single parsed row from the phone transcript CSV.
    struct ParsedRow: Sendable {
        let no: String
        let datetime: String
        let duration: String
        let status: String
        let text: String
    }

    // Parse a CSV file at the given URL, returning all data rows (skipping the header).
    // Handles BOM-prefixed UTF-8 and quoted fields with embedded newlines.
    static func parse(url: URL) throws -> [ParsedRow] {
        var content = try String(contentsOf: url, encoding: .utf8)

        // Strip the UTF-8 BOM if present at the start of the file.
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let fields = tokenizeCSV(content)
        let columnCount = 5 // No., datetime, duration, status, text

        // The first row is the header; skip it and convert remaining rows to ParsedRow.
        var rows: [ParsedRow] = []
        let totalFields = fields.count
        var fieldIndex = columnCount // Start after the header row

        while fieldIndex + columnCount <= totalFields {
            let row = ParsedRow(
                no: fields[fieldIndex],
                datetime: fields[fieldIndex + 1],
                duration: fields[fieldIndex + 2],
                status: fields[fieldIndex + 3],
                text: fields[fieldIndex + 4]
            )
            rows.append(row)
            fieldIndex += columnCount
        }

        return rows
    }

    // Tokenize a CSV string into a flat array of field values, respecting quoted fields.
    // A quoted field may contain commas, newlines, and escaped double-quotes ("").
    private static func tokenizeCSV(_ content: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        let chars = Array(content.unicodeScalars)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if insideQuotes {
                // Inside a quoted field: look for closing quote or escaped quote.
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        // Escaped double-quote inside a quoted field.
                        current.append("\"")
                        i += 2
                    } else {
                        // Closing quote ends the quoted region.
                        insideQuotes = false
                        i += 1
                    }
                } else {
                    current.unicodeScalars.append(ch)
                    i += 1
                }
            } else {
                // Outside quotes: commas and newlines delimit fields and rows.
                if ch == "\"" {
                    insideQuotes = true
                    i += 1
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                    i += 1
                } else if ch == "\r" || ch == "\n" {
                    // Handle \r\n, \r, and \n as row terminators.
                    fields.append(current)
                    current = ""
                    if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 2
                    } else {
                        i += 1
                    }
                } else {
                    current.unicodeScalars.append(ch)
                    i += 1
                }
            }
        }

        // Append the last field if the file does not end with a newline.
        if !current.isEmpty || (!fields.isEmpty && fields.count % 5 != 0) {
            fields.append(current)
        }

        return fields
    }
}
