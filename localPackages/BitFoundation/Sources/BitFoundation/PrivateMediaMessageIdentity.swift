import Foundation

/// Wire-compatible identity for private media exchanged without extending the
/// deployed file TLV. Eligible senders and receivers derive the receipt key
/// from fields that are already present on the wire.
public enum PrivateMediaMessageIdentity {
    private static let domain = Data("bitchat-private-media-message-v1".utf8)
    private static let idPrefix = "media-"
    private static let digestHexLength = 32

    public static func isStableID(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(idPrefix) else { return false }
        let digest = candidate.dropFirst(idPrefix.count)
        guard digest.utf8.count == digestHexLength else { return false }
        return digest.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    public static func stableID(
        senderPeerID: PeerID,
        recipientPeerID: PeerID,
        fileName: String?
    ) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let leafName = (fileName as NSString).lastPathComponent
        guard leafName == fileName else { return nil }

        let path = leafName as NSString
        let stem = path.deletingPathExtension
        let fileExtension = path.pathExtension.lowercased()
        switch true {
        case stem.hasPrefix("img_"):
            guard fileExtension == "jpg" || fileExtension == "jpeg" else { return nil }
        case stem.hasPrefix("voice_"):
            guard fileExtension == "m4a" else { return nil }
        default:
            return nil
        }

        let entropyToken = stem.split(separator: "_").last.map(String.init)
        let hasUUIDEntropy = entropyToken.flatMap(UUID.init(uuidString:)) != nil
        let voiceBurstID = stem.hasPrefix("voice_")
            ? String(stem.dropFirst("voice_".count))
            : ""
        let hasBurstEntropy = voiceBurstID.count == 16
            && voiceBurstID.allSatisfy(\.isHexDigit)
        guard hasUUIDEntropy || hasBurstEntropy else { return nil }

        let fields = [
            Data(senderPeerID.toShort().bare.utf8),
            Data(recipientPeerID.toShort().bare.utf8),
            Data(leafName.utf8)
        ]
        var input = domain
        for field in fields {
            guard let length = UInt32(exactly: field.count) else { return nil }
            var bigEndianLength = length.bigEndian
            withUnsafeBytes(of: &bigEndianLength) {
                input.append(contentsOf: $0)
            }
            input.append(field)
        }

        return "\(idPrefix)\(input.sha256Hex().prefix(digestHexLength))"
    }
}

/// Capability gate for the durable private-media receipt contract. Bit 8
/// permits encrypted media; both bits 8 and 9 are required for stable receipt
/// IDs and receiver-side durable deduplication.
public enum PrivateMediaReceiptPolicy {
    public static func stableMessageID(
        peerCapabilities: PeerCapabilities,
        senderPeerID: PeerID,
        recipientPeerID: PeerID,
        fileName: String?
    ) -> String? {
        guard peerCapabilities.contains(.privateMedia),
              peerCapabilities.contains(.privateMediaReceipts) else {
            return nil
        }
        return PrivateMediaMessageIdentity.stableID(
            senderPeerID: senderPeerID,
            recipientPeerID: recipientPeerID,
            fileName: fileName
        )
    }
}
