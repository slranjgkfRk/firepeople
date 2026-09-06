import Foundation

/// Exact parsing of the decimal *strings* the Toss Open API sends for every money field.
///
/// Nothing in this file ever touches `Double`/`Float`. `Decimal(string:)` reads the digits directly,
/// so a six-decimal-place USD sum (`"22417.561095"`) survives without a binary-floating-point detour.
public enum DecimalParsing {

    /// Parses a complete decimal literal. Returns `nil` for anything that is not one.
    ///
    /// `Decimal(string:)` on its own is lenient — it happily returns `12` for `"12abc"` — so the
    /// literal is validated first and only then handed over.
    public static func parse(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWellFormedLiteral(trimmed) else { return nil }
        // `locale: nil` means the POSIX form: `.` is the decimal separator, no grouping.
        return Decimal(string: trimmed, locale: nil)
    }

    /// The canonical, locale-independent text for a `Decimal`. Used whenever we write one back out.
    public static func string(from value: Decimal) -> String {
        value.description
    }

    /// `[sign] digits [ . digits ] [ (e|E) [sign] digits ]`, with at least one significant digit.
    private static func isWellFormedLiteral(_ text: String) -> Bool {
        var index = text.startIndex
        let end = text.endIndex

        func isASCIIDigit(_ character: Character) -> Bool {
            character.isASCII && character.isNumber
        }
        func consumeDigits() -> Int {
            var count = 0
            while index < end, isASCIIDigit(text[index]) {
                count += 1
                index = text.index(after: index)
            }
            return count
        }
        func consumeSign() {
            if index < end, text[index] == "+" || text[index] == "-" {
                index = text.index(after: index)
            }
        }

        consumeSign()
        let integerDigits = consumeDigits()
        var fractionDigits = 0
        if index < end, text[index] == "." {
            index = text.index(after: index)
            fractionDigits = consumeDigits()
        }
        guard integerDigits + fractionDigits > 0 else { return false }

        if index < end, text[index] == "e" || text[index] == "E" {
            index = text.index(after: index)
            consumeSign()
            guard consumeDigits() > 0 else { return false }
        }
        return index == end
    }
}

// MARK: - Decoding

extension KeyedDecodingContainer {

    /// Decodes a required decimal-string field (a bare JSON number is accepted defensively).
    ///
    /// - Throws: `DecodingError.keyNotFound` when absent, `.valueNotFound` when `null`,
    ///           `.dataCorrupted` when the text is not a decimal literal.
    public func decodeDecimal(forKey key: Key) throws -> Decimal {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No decimal value for \"\(key.stringValue)\"."
                )
            )
        }
        guard try !decodeNil(forKey: key) else {
            throw DecodingError.valueNotFound(
                Decimal.self,
                DecodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription: "Expected a decimal for \"\(key.stringValue)\" but found null."
                )
            )
        }
        return try decodeDecimalValue(forKey: key)
    }

    /// Decodes an optional decimal-string field. A missing key and an explicit `null` both give `nil`
    /// — the API sends `null` for a currency bucket with no holdings.
    public func decodeDecimalIfPresent(forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeDecimalValue(forKey: key)
    }

    private func decodeDecimalValue(forKey key: Key) throws -> Decimal {
        if let raw = try? decode(String.self, forKey: key) {
            guard let value = DecimalParsing.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "\"\(key.stringValue)\" is not a decimal literal."
                    )
                )
            }
            return value
        }
        // Defensive path: a bare JSON number. Decoded straight into `Decimal`, never via `Double`.
        if let value = try? decode(Decimal.self, forKey: key) {
            return value
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "\"\(key.stringValue)\" is neither a decimal string nor a number."
            )
        )
    }
}

extension SingleValueDecodingContainer {

    /// Same rules as `KeyedDecodingContainer.decodeDecimal(forKey:)`, for an unkeyed value.
    public func decodeDecimal() throws -> Decimal {
        if let raw = try? decode(String.self) {
            guard let value = DecimalParsing.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Value is not a decimal literal."
                    )
                )
            }
            return value
        }
        if let value = try? decode(Decimal.self) {
            return value
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Value is neither a decimal string nor a number."
            )
        )
    }
}

// MARK: - Encoding

extension KeyedEncodingContainer {

    /// Writes a `Decimal` back as the same decimal *string* the API uses, so a value round-trips
    /// exactly regardless of how the JSON coder of the day handles bare numbers.
    public mutating func encodeDecimalString(_ value: Decimal, forKey key: Key) throws {
        try encode(DecimalParsing.string(from: value), forKey: key)
    }

    /// Encodes `null` when `value` is `nil`, matching the API's own representation of "nothing held".
    public mutating func encodeDecimalStringIfPresent(_ value: Decimal?, forKey key: Key) throws {
        if let value {
            try encodeDecimalString(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
