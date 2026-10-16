import Foundation

public struct CitationSource: Equatable, Sendable {
    public var refId: String
    public var url: String
    public var title: String

    public init(refId: String, url: String, title: String) {
        self.refId = refId
        self.url = url
        self.title = title
    }
}

public enum RenderNormalizer {
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
        "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "neq": "≠", "approx": "≈",
        "equiv": "≡", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "in": "∈", "notin": "∉",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "infinity": "∞", "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏",
        "int": "∫", "oint": "∮", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "implies": "⇒",
        "therefore": "∴", "because": "∵", "degree": "°", "angle": "∠", "perp": "⊥",
    ]

    private static let superscript: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]

    private static let subscriptMap: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ",
        "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    public static func citationSources(from results: Any?) -> [CitationSource] {
        guard let list = results as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let dict = entry as? [String: Any],
                  let refId = dict["ref_id"] as? String,
                  let url = dict["url"] as? String,
                  url.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return nil
            }
            let fallback = (dict["domain"] as? String) ?? "source"
            let rawTitle = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? fallback : rawTitle
            return CitationSource(refId: refId, url: url, title: title)
        }
    }

    private static func markdownUrl(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28")
           .replacingOccurrences(of: ")", with: "%29")
           .replacingOccurrences(of: " ", with: "%20")
    }

    private static func citationLabel(_ title: String) -> String {
        let noBrackets = title.replacingOccurrences(of: #"[\[\]\n\r]+"#, with: " ", options: .regularExpression)
        let clean = noBrackets.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 46 {
            let prefix = String(clean.prefix(43)).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            return "\(prefix)…"
        }
        return clean.isEmpty ? "source" : clean
    }

    public static func resolveCitations(_ text: String, sources: [CitationSource]) -> String {
        var byId = [String: CitationSource]()
        for source in sources {
            byId[source.refId] = source
        }
        let pattern = try! NSRegularExpression(pattern: "\u{E200}cite(?:\u{E202}[^\u{E201}]*)?\u{E201}")
        let refPattern = try! NSRegularExpression(pattern: #"turn\d+(?:search|view)\d+"#)
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let marker = ns.substring(with: match.range)
            let markerNS = marker as NSString
            let refMatches = refPattern.matches(in: marker, range: NSRange(location: 0, length: markerNS.length))
            let resolved = refMatches.compactMap { byId[markerNS.substring(with: $0.range)] }
            let replacement: String
            if resolved.isEmpty {
                replacement = ""
            } else if resolved.count == 1 {
                let source = resolved[0]
                replacement = "[\(citationLabel(source.title))](\(markdownUrl(source.url)))"
            } else {
                replacement = resolved.enumerated().map { idx, source in
                    "[\(idx + 1)](\(markdownUrl(source.url)))"
                }.joined(separator: " ")
            }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        result = result.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }

    private static func readGroup(_ chars: [Character], start: Int) -> (value: String, end: Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        for idx in start..<chars.count {
            if chars[idx] == "{" {
                depth += 1
            } else if chars[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[(start + 1)..<idx]), idx + 1)
                }
            }
        }
        return nil
    }

    private static func replaceGroupedCommand(_ input: String, command: String, groups: Int, render: ([String]) -> String) -> String {
        let needle = "\\\(command)"
        let needleChars = Array(needle)
        let chars = Array(input)
        var output = ""
        var cursor = 0

        while cursor < chars.count {
            guard let found = findSubsequence(chars, needleChars, from: cursor) else {
                output.append(contentsOf: chars[cursor...])
                return output
            }
            output.append(contentsOf: chars[cursor..<found])
            var position = found + needleChars.count
            while position < chars.count && chars[position] == " " { position += 1 }
            var values = [String]()
            for _ in 0..<groups {
                guard let group = readGroup(chars, start: position) else { break }
                values.append(group.value)
                position = group.end
                while position < chars.count && chars[position] == " " { position += 1 }
            }
            if values.count != groups {
                output.append(needle)
                cursor = found + needleChars.count
            } else {
                output.append(render(values))
                cursor = position
            }
        }
        return output
    }

    private static func findSubsequence(_ haystack: [Character], _ needle: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, start + needle.count <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        for i in start...limit {
            var match = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] {
                match = false
                break
            }
            if match { return i }
        }
        return nil
    }

    private static func scriptValue(_ value: String, alphabet: [Character: String], fallback: String) -> String {
        var converted = ""
        for ch in value {
            guard let mapped = alphabet[ch] else {
                return "\(fallback)(\(value))"
            }
            converted.append(mapped)
        }
        return converted
    }

    private static func replaceRegex(_ input: String, pattern: String, options: NSRegularExpression.Options = [], transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var result = input
        for match in matches.reversed() {
            var groups = [String]()
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location != NSNotFound ? ns.substring(with: r) : "")
            }
            let replacement = transform(groups)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    public static func formatLatex(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            value = replaceGroupedCommand(value, command: "frac", groups: 2) { parts in
                "(\(formatLatex(parts[0])))/(\(formatLatex(parts[1])))"
            }
            value = replaceGroupedCommand(value, command: "sqrt", groups: 1) { parts in
                "√(\(formatLatex(parts[0])))"
            }
            value = replaceGroupedCommand(value, command: "text", groups: 1) { parts in parts[0] }
            value = replaceGroupedCommand(value, command: "operatorname", groups: 1) { parts in parts[0] }
        }
        value = value.replacingOccurrences(of: #"\\begin\{(?:aligned\*?|equation\*?|gathered|matrix|pmatrix|bmatrix)\}"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\end\{(?:aligned\*?|equation\*?|gathered|matrix|pmatrix|bmatrix)\}"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\(?:left|right|displaystyle)\b"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\(?:quad|qquad|,|;|!|:)\s*"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\\\"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "&", with: "")
        value = replaceRegex(value, pattern: #"\\([A-Za-z]+)"#) { groups in
            symbols[groups[1]] ?? groups[1]
        }
        value = replaceRegex(value, pattern: #"\^\{([^{}]+)\}"#) { groups in
            scriptValue(groups[1], alphabet: superscript, fallback: "^")
        }
        value = replaceRegex(value, pattern: #"_\{([^{}]+)\}"#) { groups in
            scriptValue(groups[1], alphabet: subscriptMap, fallback: "_")
        }
        value = replaceRegex(value, pattern: #"\^([0-9+\-=()ni])"#) { groups in
            if let ch = groups[1].first, let s = superscript[ch] { return s }
            return "^\(groups[1])"
        }
        value = replaceRegex(value, pattern: #"_([0-9+\-=()aehijklmnoprstuvx])"#) { groups in
            if let ch = groups[1].first, let s = subscriptMap[ch] { return s }
            return "_\(groups[1])"
        }
        value = value.replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "~", with: " ")
        value = value.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*([=+×÷±≤≥≠≈→])\s*"#, with: " $1 ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mathFence(_ expression: String) -> String {
        "\n\n```math\n\(formatLatex(expression))\n```\n\n"
    }

    public static func normalizeMath(_ markdown: String) -> String {
        var value = markdown
        value = replaceRegex(value, pattern: #"\$\$([\s\S]*?)\$\$"#) { mathFence($0[1]) }
        value = replaceRegex(value, pattern: #"\\\[([\s\S]*?)\\\]"#) { mathFence($0[1]) }
        value = replaceRegex(value, pattern: #"\\begin\{equation\*?\}([\s\S]*?)\\end\{equation\*?\}"#) { mathFence($0[1]) }
        value = replaceRegex(value, pattern: #"\\\(([\s\S]*?)\\\)"#) { formatLatex($0[1]) }
        value = replaceRegex(value, pattern: #"\$([^$\n]+)\$"#) { groups in
            let expr = groups[1]
            if expr.range(of: #"\\[A-Za-z]+|[=^_+*/<>]|^[A-Za-z]$"#, options: .regularExpression) != nil {
                return formatLatex(expr)
            }
            return groups[0]
        }
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeAssistantText(_ text: String, sources: [CitationSource] = []) -> String {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var protectedCode = [String]()
        var sentinel = "\u{E000}SPEEDCHAT_CODE_"
        while source.contains(sentinel) { sentinel += "_" }

        let codePattern = #"(^|\n)(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:\n\2[^\n]*(?=\n|$)|$)|(`+)[^`\n]*?\3"#
        let prose = replaceRegex(source, pattern: codePattern) { groups in
            let idx = protectedCode.count
            protectedCode.append(groups[0])
            return "\(sentinel)\(idx)\u{E001}"
        }
        var normalized = normalizeMath(resolveCitations(prose, sources: sources))
        for (idx, code) in protectedCode.enumerated() {
            normalized = normalized.replacingOccurrences(of: "\(sentinel)\(idx)\u{E001}", with: code)
        }
        return normalized
    }
}

public struct StreamingCitationResolver: Sendable {
    private var tail = ""
    public init() {}

    public mutating func reset() {
        tail = ""
    }

    public mutating func push(_ delta: String, sources: [CitationSource]) -> String {
        var input = tail + delta
        tail = ""
        var output = ""

        while !input.isEmpty {
            guard let start = input.firstIndex(of: "\u{E200}") else {
                return output + input
            }
            output += input[..<start]
            let afterStart = input.index(after: start)
            guard let end = input[afterStart...].firstIndex(of: "\u{E201}") else {
                tail = String(input[start...])
                return output
            }
            let afterEnd = input.index(after: end)
            let marker = String(input[start..<afterEnd])
            output += RenderNormalizer.resolveCitations(marker, sources: sources)
            input = String(input[afterEnd...])
        }
        return output
    }
}

public struct StreamingLinkResolver: Sendable {
    private var tail = ""
    public init() {}

    public mutating func reset() {
        tail = ""
    }

    public mutating func push(_ delta: String) -> String {
        var chars = Array(tail + delta)
        tail = ""
        var output = ""

        while !chars.isEmpty {
            guard let bracket = chars.firstIndex(of: "[") else {
                output.append(contentsOf: chars)
                return output
            }
            let start = (bracket > 0 && chars[bracket - 1] == "!") ? bracket - 1 : bracket
            output.append(contentsOf: chars[0..<start])

            let searchStart = bracket + 1
            let labelEnd = searchStart < chars.count ? chars[searchStart...].firstIndex(of: "]") : nil
            let labelNewline = searchStart < chars.count ? chars[searchStart...].firstIndex(of: "\n") : nil

            if let nl = labelNewline, (labelEnd == nil || nl < labelEnd!) {
                output.append(contentsOf: chars[start...(bracket)])
                chars.removeFirst(bracket + 1)
                continue
            }
            guard let lEnd = labelEnd, lEnd + 1 < chars.count else {
                tail = String(chars[start...])
                return output
            }
            if chars[lEnd + 1] != "(" {
                output.append(contentsOf: chars[start...lEnd])
                chars.removeFirst(lEnd + 1)
                continue
            }

            var depth = 0
            var linkEnd: Int? = nil
            var linkNewline = false
            for idx in (lEnd + 1)..<chars.count {
                if chars[idx] == "\n" {
                    linkNewline = true
                    break
                }
                if chars[idx] == "(" {
                    depth += 1
                } else if chars[idx] == ")" {
                    depth -= 1
                    if depth == 0 {
                        linkEnd = idx
                        break
                    }
                }
            }
            if linkNewline {
                output.append(contentsOf: chars[start...(lEnd + 1)])
                chars.removeFirst(lEnd + 2)
                continue
            }
            guard let finalEnd = linkEnd else {
                tail = String(chars[start...])
                return output
            }

            let label = String(chars[(bracket + 1)..<lEnd])
            let url = String(chars[(lEnd + 2)..<finalEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if url.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                output += "[\(label)](\(url))"
            } else {
                output.append(contentsOf: chars[start...finalEnd])
            }
            chars.removeFirst(finalEnd + 1)
        }
        return output
    }
}
