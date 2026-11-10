import Foundation

/// Something the command line asked for when the app was started.
enum LaunchRequest: Equatable {
    /// Show this workspace (by id or name), as `--space Development` says.
    case space(String)
}

enum LaunchArgumentError: Error, Equatable {
    case missingValue(flag: String)
    case repeated(flag: String)

    var message: String {
        switch self {
        case .missingValue(let flag): "\(flag) needs a workspace name, for example: \(flag) \"Development\"."
        case .repeated(let flag): "\(flag) was given more than once. Give it once."
        }
    }
}

/// Reads the arguments the app was started with. Only the flags below mean anything; every other argument (the system adds several of its own, such as
/// `-NSDocumentRevisionsDebugMode` or `-ApplePersistenceIgnoreState`) is left alone. No view and no model is involved: this is plain text in, requests out.
enum LaunchArgumentParser {
    static let spaceFlag = "--space"

    static func parse(_ arguments: [String]) -> Result<[LaunchRequest], LaunchArgumentError> {
        var space: String?
        var seen = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            let value: String?
            if argument == spaceFlag {
                // The value is the next argument, unless that is another flag (`--space --other`), which is a missing value.
                if index < arguments.count, !arguments[index].hasPrefix("--") { value = arguments[index]; index += 1 } else { value = nil }
            } else if argument.hasPrefix(spaceFlag + "=") {
                value = String(argument.dropFirst(spaceFlag.count + 1))
            } else {
                continue
            }
            if seen { return .failure(.repeated(flag: spaceFlag)) }
            seen = true
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clean.isEmpty else { return .failure(.missingValue(flag: spaceFlag)) }
            space = String(clean.prefix(120))
        }
        return .success(space.map { [.space($0)] } ?? [])
    }
}

enum SpaceLookupError: Error, Equatable {
    case notFound(query: String, known: [String])
    case ambiguous(query: String, matches: [String])

    var message: String {
        switch self {
        case .notFound(let query, let known):
            let list = known.isEmpty ? "" : " Workspaces: " + known.joined(separator: ", ") + "."
            return "There is no workspace called “\(query)”." + list
        case .ambiguous(let query, let matches):
            return "“\(query)” could mean more than one workspace: " + matches.joined(separator: ", ") + ". Use the exact name."
        }
    }
}

/// Finds the workspace a request means. The id comes first, then the exact name, then the name without regard to capital letters (only when that is
/// unambiguous). A workspace's id is its name today, so the first two steps agree; they are kept apart so a stable id can be added without changing callers.
/// "Personal" (the built-in workspace, id empty) can be asked for by that name.
enum SpaceLookup {
    static let personalName = "Personal"

    /// The id to switch to (empty means Personal), or why none matches.
    static func resolve(_ query: String, in workspaces: [Workspace]) -> Result<String, SpaceLookupError> {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [personalName] + workspaces.map(\.name)
        // The hidden identity first: it still finds a workspace that has been renamed since the request was written down.
        if let byUID = workspaces.first(where: { $0.uid == wanted && !wanted.isEmpty }) { return .success(byUID.name) }
        if wanted == personalName { return .success("") }
        let exact = workspaces.filter { $0.name == wanted }
        if exact.count == 1 { return .success(exact[0].id) }
        let loose = (workspaces.map { ($0.id, $0.name) } + [("", personalName)]).filter { $0.1.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if loose.count == 1 { return .success(loose[0].0) }
        if loose.count > 1 { return .failure(.ambiguous(query: wanted, matches: loose.map(\.1))) }
        return .failure(.notFound(query: wanted, known: names))
    }
}
