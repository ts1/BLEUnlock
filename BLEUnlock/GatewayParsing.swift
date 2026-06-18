import Foundation

/// Extracts the IPv4 default-gateway address from `route -n get default` output.
func parseDefaultGatewayIP(routeOutput: String) -> String? {
    for line in routeOutput.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("gateway:") {
            let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }
    return nil
}

/// Normalises a MAC to lower-case, colon-separated, zero-padded octets.
/// macOS `arp` prints octets without leading zeros (e.g. "a4:2b:8c:1:2:3"), so padding
/// keeps allowlist comparisons stable. Returns nil for anything that is not 6 hex octets.
func normalizeMAC(_ raw: String) -> String? {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return nil }
    var octets: [String] = []
    for part in parts {
        // The isHexDigit guard is required: Swift's Int(_:radix:) accepts a leading
        // '+'/'-', so e.g. "-1" would otherwise parse and emit a malformed octet.
        guard (1...2).contains(part.count),
              part.allSatisfy({ $0.isHexDigit }),
              let value = Int(part, radix: 16) else { return nil }
        octets.append(String(format: "%02x", value))
    }
    return octets.joined(separator: ":")
}

/// Extracts and normalises the gateway MAC from `arp -n <ip>` output, e.g.
/// "? (10.0.0.1) at a4:2b:8c:1:2:3 on en0 ifscope [ethernet]".
func parseGatewayMAC(arpOutput: String) -> String? {
    let tokens = arpOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    guard let atIndex = tokens.firstIndex(of: "at"), atIndex + 1 < tokens.count else { return nil }
    let macToken = String(tokens[atIndex + 1])
    if macToken == "(incomplete)" { return nil }
    return normalizeMAC(macToken)
}

/// Pause state with sticky behaviour: an unresolved MAC keeps the previous state, so a
/// transient ARP/route hiccup does not flip the pause off (or on) spuriously.
func computePauseState(resolvedMAC: String?, allowlist: Set<String>, previous: Bool) -> Bool {
    guard let mac = resolvedMAC else { return previous }
    return allowlist.contains(mac)
}
