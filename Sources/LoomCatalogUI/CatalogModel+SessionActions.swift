import Foundation

/// The Dock icon's menu (W3-f): the sessions with a request waiting for the user, then the sessions working, at most five each,
/// then New Claude Session where the model offers it (C2B). Built when the Dock asks, from what the model already holds (the menu
/// bar's entries): no read.
public enum DockMenu {
    public static let needsYouHeader = MenuBarMenu.needsYouHeader
    public static let workingHeader = MenuBarMenu.workingHeader
    public static let newSessionTitle = "New Claude Session"

    /// A request waits: an approval first, then a question or a plan, each most recent first. A finished turn or a failure is not
    /// a request, so the Dock leaves it to the menu bar and the sidebar.
    static func requestRank(_ indicator: SessionIndicator) -> Int? {
        switch indicator {
        case .waitingForApproval: 0
        case .waitingForInput: 1
        default: nil
        }
    }

    public static func items(for entries: [MenuBarEntry], canStartSession: Bool, offersNewSession: Bool = true) -> [MenuBarMenuItem] {
        func recentFirst(_ lhs: MenuBarEntry, _ rhs: MenuBarEntry) -> Bool {
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let needing = entries.compactMap { entry in requestRank(entry.indicator).map { (entry, $0) } }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : recentFirst(lhs.0, rhs.0) }
            .prefix(MenuBarState.maxRows).map(\.0)
        let working = entries.filter { $0.indicator == .working }.sorted(by: recentFirst).prefix(MenuBarState.maxRows)
        func item(_ kind: MenuBarMenuItem.Kind, _ title: String, entry: MenuBarEntry? = nil, enabled: Bool = true) -> MenuBarMenuItem {
            MenuBarMenuItem(kind: kind, title: title, project: entry?.project, enabled: enabled, sessionID: entry?.id,
                            attention: nil, key: nil)
        }
        var items: [MenuBarMenuItem] = []
        if !needing.isEmpty {
            items.append(item(.header, needsYouHeader, enabled: false))
            items += needing.map { item(.needsYouSession, $0.title, entry: $0) }
        }
        if !working.isEmpty {
            items.append(item(.header, workingHeader, enabled: false))
            items += working.map { item(.workingSession, $0.title, entry: $0) }
        }
        if offersNewSession {
            if !items.isEmpty { items.append(item(.separator, "")) }
            items.append(item(.newSession, newSessionTitle, enabled: canStartSession))
        }
        return items
    }

    /// A session row as the Dock prints it: one plain line, the title and then the project.
    public static func rowTitle(_ item: MenuBarMenuItem) -> String {
        guard let project = item.project, !project.isEmpty else { return item.title }
        return "\(item.title) \u{2014} \(project)"
    }
}

extension CatalogModel {
    /// The Dock menu now (`DockMenu`). New Claude Session is enabled where ⌘N is, and listed where the model offers it (C2B).
    public func dockMenuItems() -> [MenuBarMenuItem] {
        DockMenu.items(for: menuBarEntries(), canStartSession: canStart(.newSessionDefault, projectID: contextProjectID),
                       offersNewSession: offersNewSession(.newSessionDefault))
    }
}

extension CatalogModel {
    /// The palette's Reveal in Finder: the selected session's folder, else the folder of the project on screen (its page or its
    /// draft), with the name the row's detail says. Nil when there is neither or the folder is gone.
    func revealInFinderTarget(folderExists: (String) -> Bool = SessionLocationActions.directoryExists) -> (path: String, name: String)? {
        if let row = selectedRow {
            let path = row.record.session.workingDirectory
            return folderExists(path) ? (path, title(of: row)) : nil
        }
        guard let id = contextProjectID, let project = projects.first(where: { $0.id == id }),
              folderExists(project.path) else { return nil }
        return (project.path, project.name)
    }
}
