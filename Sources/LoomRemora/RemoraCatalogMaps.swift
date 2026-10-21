import Foundation
import LoomCore

/// What `RemoraMemory.share` and `apply` need of the catalog and `SessionDirectory` does not give: every known session's
/// project (the excluded projects' sessions included, so the share can keep their journal lines out) and the names of the
/// projects Remora may name. One catalog read with no row limit (`SessionDirectory` stops at 100 rows, which would leave
/// older sessions without a project).
public struct RemoraCatalogMaps: Equatable, Sendable {
    /// Every listed session to its project; a session without a project is not in it.
    public var sessionProjects: [UUID: UUID]
    /// The name of every project that has a listed session.
    public var projectNames: [UUID: String]
    /// Each listed session's project and last activity, newest activity first.
    var recency: [(project: UUID?, activity: Date)]

    public init(sessionProjects: [UUID: UUID] = [:], projectNames: [UUID: String] = [:],
                recency: [(project: UUID?, activity: Date)] = []) {
        self.sessionProjects = sessionProjects
        self.projectNames = projectNames
        self.recency = recency
    }

    public static func == (left: Self, right: Self) -> Bool {
        left.sessionProjects == right.sessionProjects && left.projectNames == right.projectNames
            && left.recency.count == right.recency.count
            && zip(left.recency, right.recency).allSatisfy { $0.project == $1.project && $0.activity == $1.activity }
    }

    /// The catalog's listed sessions (no side chat, nothing being deleted): one read, newest activity first.
    public static func read(from catalog: SessionCatalog) async throws -> Self {
        let rows = try await catalog.directoryRows(project: nil, excluding: [], limit: .max)
        var maps = Self()
        for row in rows {
            let id = row.record.session.id
            if let project = row.record.projectID {
                maps.sessionProjects[id] = project
                if let name = row.projectName { maps.projectNames[project] = name }
            }
            maps.recency.append((row.record.projectID, row.record.lastActivityAt))
        }
        return maps
    }

    /// The projects a pack's index shows: those of the newest `rows` sessions outside the excluded projects, with their
    /// names (the stable memory lists the projects a brief's notes may name, and the pack's index is what it may cite).
    public func namedProjects(excluding excluded: Set<UUID>, indexRows: Int = RemoraPackLimits.standard.indexRows) -> [UUID: String] {
        var named: [UUID: String] = [:]
        var seen = 0
        for entry in recency where entry.project.map(excluded.contains) != true {
            seen += 1
            if seen > indexRows { break }
            if let project = entry.project, let name = projectNames[project] { named[project] = name }
        }
        return named
    }

    /// The newest activity of any session outside the excluded projects (their sessions never move a brief).
    public func newestActivity(excluding excluded: Set<UUID>) -> Date? {
        recency.first { $0.project.map(excluded.contains) != true }?.activity
    }
}
