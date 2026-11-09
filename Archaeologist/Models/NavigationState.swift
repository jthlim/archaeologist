import Foundation

public struct NavigationState: Equatable {
    public let fileURL: URL
    public let revision: String
    public let vcsType: VCSType

    public init(fileURL: URL, revision: String, vcsType: VCSType) {
        self.fileURL = fileURL.standardizedFileURL
        self.revision = revision
        self.vcsType = vcsType
    }

    public static func == (lhs: NavigationState, rhs: NavigationState) -> Bool {
        return lhs.fileURL.standardizedFileURL.path == rhs.fileURL.standardizedFileURL.path &&
               lhs.revision == rhs.revision &&
               lhs.vcsType == rhs.vcsType
    }
}
