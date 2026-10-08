import Foundation

// Gmail API resources (https://developers.google.com/gmail/api/reference/rest), only the fields vimail reads.

struct GmailProfile: Decodable {
    var emailAddress: String
    var historyId: String
    var messagesTotal: Int?
    var threadsTotal: Int?
}

struct GmailLabel: Decodable {
    struct Color: Decodable {
        var textColor: String?
        var backgroundColor: String?
    }

    var id: String
    var name: String
    var type: String?
    var labelListVisibility: String?
    var color: Color?
}

struct GmailLabelList: Decodable {
    var labels: [GmailLabel]?
}

struct GmailThreadList: Decodable {
    struct Item: Decodable {
        var id: String
    }

    var threads: [Item]?
    var nextPageToken: String?
}

struct GmailThread: Decodable {
    var id: String
    var messages: [GmailMessage]?
}

struct GmailMessageRef: Decodable {
    var id: String
    var threadId: String
    var labelIds: [String]?
}

struct GmailMessageList: Decodable {
    var messages: [GmailMessageRef]?
    var nextPageToken: String?
}

struct GmailMessage: Decodable {
    var id: String
    var threadId: String
    var labelIds: [String]?
    var snippet: String?
    var internalDate: String?
    var sizeEstimate: Int?
    var payload: GmailPart?
}

struct GmailPart: Decodable {
    var partId: String?
    var mimeType: String?
    var filename: String?
    var headers: [GmailHeader]?
    var body: GmailBody?
    var parts: [GmailPart]?

    /// First header with this name, case-insensitively.
    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct GmailHeader: Decodable {
    var name: String
    var value: String
}

struct GmailBody: Decodable {
    var attachmentId: String?
    var size: Int?
    var data: String?
}

struct GmailAttachmentBody: Decodable {
    var size: Int?
    var data: String?
}

struct GmailHistoryList: Decodable {
    struct Record: Decodable {
        struct MessageEntry: Decodable {
            var message: GmailMessageRef
        }

        var id: String?
        var messagesAdded: [MessageEntry]?
        var messagesDeleted: [MessageEntry]?
        var labelsAdded: [MessageEntry]?
        var labelsRemoved: [MessageEntry]?
    }

    var history: [Record]?
    var nextPageToken: String?
    var historyId: String?
}

struct GmailSendAs: Decodable {
    var sendAsEmail: String
    var displayName: String?
    var signature: String?
    var isPrimary: Bool?
    var isDefault: Bool?
}

struct GmailSendAsList: Decodable {
    var sendAs: [GmailSendAs]?
}

/// Request body for `messages.batchModify`.
struct GmailBatchModify: Encodable {
    var ids: [String]
    var addLabelIds: [String]
    var removeLabelIds: [String]
}

/// Request body for `labels.create` and `labels.patch`.
struct GmailLabelRequest: Encodable {
    var name: String
    var labelListVisibility: String?
    var messageListVisibility: String?
}
