import Foundation

struct FormField {
    let name: String
    let type: String
    var value: String
}

// A login form parsed out of a captive-portal page.
struct LoginForm {
    let action: String   // raw action attribute (may be relative or empty)
    var fields: [FormField]

    // Fills the password field(s) and the first visible text field (the
    // username), leaving hidden fields (tokens, dst, popup, …) untouched.
    func filled(username: String, password: String) -> [(String, String)] {
        var result = fields
        for i in result.indices where result[i].type == "password" {
            result[i].value = password
        }
        if let idx = result.firstIndex(where: { ["text", "email", "tel"].contains($0.type) }) {
            result[idx].value = username
        }
        return result.map { ($0.name, $0.value) }
    }
}

// Minimal, dependency-free HTML form parser for standard captive portals.
// Not a full HTML parser: it handles the plain `<form>`/`<input>` markup these
// portals use. JS-rendered or CHAP-challenge portals won't be discovered and
// fall back to the manually configured endpoint.
enum LoginFormParser {
    // Returns the first <form> that contains a password input.
    static func parse(html: String) -> LoginForm? {
        for form in regexMatches("(?is)<form\\b.*?</form>", html) {
            let inputs = parseInputs(form)
            guard inputs.contains(where: { $0.type == "password" }) else { continue }
            let openTag = regexMatches("(?is)<form\\b[^>]*>", form).first ?? ""
            let action = attribute("action", in: openTag) ?? ""
            return LoginForm(action: action, fields: inputs)
        }
        return nil
    }

    private static func parseInputs(_ formHTML: String) -> [FormField] {
        var fields: [FormField] = []
        for tag in regexMatches("(?is)<input\\b[^>]*>", formHTML) {
            guard let name = attribute("name", in: tag), !name.isEmpty else { continue }
            let type = (attribute("type", in: tag) ?? "text").lowercased()
            let value = attribute("value", in: tag) ?? ""
            fields.append(FormField(name: name, type: type, value: value))
        }
        return fields
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let raw = firstCapture("(?i)\\b\(name)\\s*=\\s*\"([^\"]*)\"", tag)
            ?? firstCapture("(?i)\\b\(name)\\s*=\\s*'([^']*)'", tag)
        return raw.map(decodeEntities)
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x2F;": "/", "&#47;": "/"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }

    private static func regexMatches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
