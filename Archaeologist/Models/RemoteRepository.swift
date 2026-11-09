import Foundation

public struct RemoteRepository: Identifiable, Equatable, Hashable {
    public let name: String
    public let urlString: String?

    public var id: String { name }

    public init(name: String, urlString: String? = nil) {
        self.name = name
        self.urlString = urlString
    }
}
