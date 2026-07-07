import Foundation

func sanitizedMetadataText(_ value: String) -> String {
    let decoded = decodeHTMLEntitiesRepeatedly(value)
    let anchorsPreserved = preservingAnchorLinks(in: decoded)
    let withBreaks = replacingHTMLBreaks(in: anchorsPreserved)
    let withoutTags = replacingMatches(
        pattern: "<[^>]+>",
        in: withBreaks,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) { _ in " " }
    return normalizedMetadataWhitespace(decodeHTMLEntitiesRepeatedly(withoutTags))
}

func metadataURLs(in value: String) -> [String] {
    let decoded = decodeHTMLEntitiesRepeatedly(value)
    var urls: [String] = []

    let anchorPattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]+)"|'([^']+)'|([^'"\s>]+))[^>]*>"#
    urls.append(contentsOf: matches(
        pattern: anchorPattern,
        in: decoded,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    ).compactMap { match in
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: decoded) {
                return String(decoded[range])
            }
        }
        return nil
    })

    let urlPattern = #"https?://[^\s<>"']+"#
    urls.append(contentsOf: matches(pattern: urlPattern, in: decoded).compactMap { match in
        guard let range = Range(match.range, in: decoded) else { return nil }
        return String(decoded[range])
    })

    var seen: Set<String> = []
    return urls.compactMap { canonicalSourceURL($0) }.filter { seen.insert($0).inserted }
}

func makerWorldModelURL(from value: String) -> String? {
    let decoded = decodeHTMLEntitiesRepeatedly(value)
    guard let match = matches(pattern: #"\d{3,}"#, in: decoded).first,
          let range = Range(match.range, in: decoded) else { return nil }
    return "https://makerworld.com/en/models/\(decoded[range])"
}

func isUsefulSourceURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    let imageExtensions = ["gif", "jpeg", "jpg", "png", "svg", "webp"]
    return !imageExtensions.contains(url.pathExtension.lowercased())
}

private func decodeHTMLEntitiesRepeatedly(_ value: String) -> String {
    var current = value
    for _ in 0..<4 {
        let decoded = decodeHTMLEntitiesOnce(current)
        if decoded == current { return decoded }
        current = decoded
    }
    return current
}

private func decodeHTMLEntitiesOnce(_ value: String) -> String {
    let pattern = #"&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#
    var result = ""
    var cursor = value.startIndex

    for match in matches(pattern: pattern, in: value) {
        guard let fullRange = Range(match.range, in: value),
              let entityRange = Range(match.range(at: 1), in: value) else { continue }
        result += value[cursor..<fullRange.lowerBound]
        result += decodedEntity(String(value[entityRange])) ?? String(value[fullRange])
        cursor = fullRange.upperBound
    }

    result += value[cursor...]
    return result
}

private func decodedEntity(_ entity: String) -> String? {
    let named = [
        "amp": "&",
        "apos": "'",
        "gt": ">",
        "lt": "<",
        "nbsp": " ",
        "quot": "\""
    ]
    if let value = named[entity.lowercased()] { return value }

    let scalarValue: UInt32?
    if entity.lowercased().hasPrefix("#x") {
        scalarValue = UInt32(entity.dropFirst(2), radix: 16)
    } else if entity.hasPrefix("#") {
        scalarValue = UInt32(entity.dropFirst(), radix: 10)
    } else {
        scalarValue = nil
    }
    guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { return nil }
    return String(scalar)
}

private func preservingAnchorLinks(in value: String) -> String {
    let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]+)"|'([^']+)'|([^'"\s>]+))[^>]*>(.*?)</a>"#
    return replacingMatches(
        pattern: pattern,
        in: value,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) { match in
        let href = (1...3).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }.first ?? ""
        let label = Range(match.range(at: 4), in: value).map {
            sanitizedMetadataText(String(value[$0]))
        } ?? ""

        guard !href.isEmpty, !label.localizedCaseInsensitiveContains(href) else {
            return label
        }
        return label.isEmpty ? href : "\(label) \(href)"
    }
}

private func replacingHTMLBreaks(in value: String) -> String {
    replacingMatches(
        pattern: #"<\s*(br|/p|/div|/h[1-6]|/li)\b[^>]*>"#,
        in: value,
        options: [.caseInsensitive]
    ) { _ in "\n" }
}

private func normalizedMetadataWhitespace(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .components(separatedBy: .newlines)
        .map { line in
            replacingMatches(pattern: #"[ \t\r\f]+"#, in: line) { _ in " " }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func canonicalSourceURL(_ value: String) -> String? {
    let trimmed = decodeHTMLEntitiesRepeatedly(value)
        .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"'“”‘’<>.,;:!?)）]}】」』"))
    guard let url = URL(string: trimmed),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return isUsefulSourceURL(url.absoluteString) ? url.absoluteString : nil
}

private func matches(
    pattern: String,
    in value: String,
    options: NSRegularExpression.Options = []
) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return regex.matches(
        in: value,
        options: [],
        range: NSRange(value.startIndex..., in: value)
    )
}

private func replacingMatches(
    pattern: String,
    in value: String,
    options: NSRegularExpression.Options = [],
    replacement: (NSTextCheckingResult) -> String
) -> String {
    let allMatches = matches(pattern: pattern, in: value, options: options)
    guard !allMatches.isEmpty else { return value }

    var result = ""
    var cursor = value.startIndex
    for match in allMatches {
        guard let range = Range(match.range, in: value) else { continue }
        result += value[cursor..<range.lowerBound]
        result += replacement(match)
        cursor = range.upperBound
    }
    result += value[cursor...]
    return result
}
