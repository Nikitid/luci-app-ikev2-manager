import Foundation

public struct HostEntry: Codable, Sendable {
    public let address: String
    public let domain: String

    public init(address: String, domain: String) {
        self.address = address
        self.domain = domain
    }
}

public enum HostsError: Error {
    case invalidDocument, invalidEntry, malformedBlock, conflictingEntry
}

/// Pure transformation. The privileged caller owns locking, guard verification,
/// metadata preservation and atomic replacement of the actual hosts file.
public enum ManagedHosts {
    private static let begin = "# BEGIN IKEv2 Manager managed hosts"
    private static let end = "# END IKEv2 Manager managed hosts"

    public static func reconcile(_ original: String, entries: [HostEntry]) throws -> String {
        guard original.utf8.count <= 1_048_576, !original.contains("\0"),
              !original.replacingOccurrences(of: "\r\n", with: "\n").contains("\r"),
              entries.count <= 4096 else { throw HostsError.invalidDocument }
        var domains = Set<String>()
        var addresses = Set<String>()
        for entry in entries {
            let octets = entry.address.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets.allSatisfy({ octet in
                      guard let number = UInt8(octet) else { return false }
                      return String(number) == octet
                  }),
                  entry.domain.utf8.count <= 253,
                  entry.domain.range(of: #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z"#, options: .regularExpression) != nil,
                  entry.domain.range(of: #"\A[0-9.]+\z"#, options: .regularExpression) == nil,
                  domains.insert(entry.domain).inserted,
                  addresses.insert(entry.address).inserted else { throw HostsError.invalidEntry }
        }
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        var kept: [String] = []
        var inBlock = false
        var seenBlock = false
        for rawLine in original.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line == begin {
                guard !inBlock, !seenBlock else { throw HostsError.malformedBlock }
                inBlock = true
                seenBlock = true
            } else if line == end {
                guard inBlock else { throw HostsError.malformedBlock }
                inBlock = false
            } else if !inBlock {
                let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.dropFirst().contains(where: {
                    let name = $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domains.contains(name)
                }) { throw HostsError.conflictingEntry }
                kept.append(rawLine)
            }
        }
        guard !inBlock else { throw HostsError.malformedBlock }
        var result = kept.joined(separator: "\n")
        guard !entries.isEmpty else { return result }
        if !result.isEmpty && result.utf8.last != 10 { result += newline }
        result += begin + newline
        for entry in entries { result += "\(entry.address) \(entry.domain)" + newline }
        result += end + newline
        return result
    }
}
