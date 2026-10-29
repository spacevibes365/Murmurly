import Darwin
import Foundation

/// Reading the meetings and dictations as they are on disk, shared by the app
/// and the `murmurly` helper. Nothing here may depend on the app's objects,
/// the main actor or the audio frameworks: the helper builds it on its own.
enum Archive {
    /// How a file read treats a symbolic link in its own path (its parent
    /// folders always follow links; this is about the file or folder itself).
    /// `follow` is the window's own behavior, unchanged by this card. `refuse`
    /// is for the helper, reading someone else's files: a link, dangling or
    /// not, is an error rather than a silent read of whatever it points to.
    enum Links: Sendable {
        case follow
        case refuse
    }

    /// Why a `refuse` read did not happen; English only, as this is the
    /// helper's own error, not interface text.
    enum ReadError: LocalizedError, Equatable {
        case link(String)
        case notAFile(String)
        /// Nothing at the path at all: callers that treat an absent file as
        /// empty, rather than an error, match on this case alone.
        case missing(String)
        case unreadable(String, String)

        var errorDescription: String? {
            switch self {
            case .link(let path): return "\(path) is a link"
            case .notAFile(let path): return "\(path) is not a plain file"
            case .missing(let path): return "\(path) does not exist"
            case .unreadable(let path, let reason): return "\(path) can’t be read: \(reason)"
            }
        }
    }

    /// A file's bytes. `follow` is a plain read. `refuse` opens with
    /// `O_NOFOLLOW`: a link in the file's own name, dangling or not, is
    /// `ReadError.link`, never opened.
    static func read(_ url: URL, links: Links) throws -> Data {
        switch links {
        case .follow:
            return try Data(contentsOf: url)
        case .refuse:
            let path = url.path
            let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else {
                let code = errno
                if code == ELOOP { throw ReadError.link(path) }
                if code == ENOENT || code == ENOTDIR { throw ReadError.missing(path) }
                throw ReadError.unreadable(path, String(cString: strerror(code)))
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw ReadError.unreadable(path, String(cString: strerror(errno)))
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notAFile(path) }
            return (try handle.readToEnd()) ?? Data()
        }
    }

    /// Whether a cheap, literal "does the raw text contain these characters"
    /// check of `query` can safely stand in for the real parser/decoder
    /// before deciding a candidate is worth the expensive full read — shared
    /// by the meeting search's quick check (`MeetingFolder.transcript`) and
    /// the dictation search's (`mayMatch` in `Dictations.swift`). `false`
    /// whenever the check could lose a match that the real path would find:
    /// an empty query, or one whose first scalar would combine with
    /// whatever precedes it in the raw text (a combining mark it would not
    /// combine with inside the parsed/decoded form) rather than start a new,
    /// independent match. When this is `false`, every candidate is treated
    /// as a possible match — nothing is ever skipped because of it.
    static func quickCheckApplies(to query: String) -> Bool {
        guard let first = query.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else { return false }
        if first.value == 0x200D { return false }
        if first.properties.isGraphemeExtend { return false }
        switch first.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return false
        default: return true
        }
    }
}
