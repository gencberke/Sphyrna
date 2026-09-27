import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Explicitly use the property-wrapper type; CLT-only SDKs may omit SwiftUI macro plugins.
private typealias StoredState<Value> = SwiftUI.State<Value>

enum Palette {
    static let sidebar = Color(red: 0.043, green: 0.055, blue: 0.086)
    static let panel = Color(red: 0.114, green: 0.110, blue: 0.133)
    static let accent = Color(red: 0.53, green: 0.57, blue: 0.81)
    static let text = Color(red: 0.88, green: 0.86, blue: 0.92)
    static let muted = Color(red: 0.46, green: 0.48, blue: 0.55)
    static let border = Color.white.opacity(0.09)
    static let unread = Color(red: 0.36, green: 0.58, blue: 0.98)
}

struct DesktopView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StoredState<Double> private var savedSidebarWidth = 300.0
    @StoredState<String?> private var draggedProjectID: String?

    private let sidebarMinWidth = 220.0
    private let sidebarMaxWidth = 520.0
    private let minimumTerminalWidth = 480.0
    // The window's unified toolbar is 52 pt tall with the window buttons centered in it;
    // header controls share that center line and start clear of the zoom button.
    private let titleBarHeight = 52.0
    private let titleBarLeadingInset = 86.0

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = effectiveSidebarWidth(for: geometry.size.width)
            let terminalDropArea = CGRect(x: sidebarWidth, y: 46,
                                          width: geometry.size.width - sidebarWidth - 8,
                                          height: geometry.size.height - 54)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    sidebar(terminalDropArea: terminalDropArea)
                        .frame(width: sidebarWidth)
                }
                VStack(spacing: 0) {
                    if !model.sidebarVisible {
                        HStack(spacing: 8) {
                            sidebarToggle
                            Spacer()
                        }
                        .padding(.leading, titleBarLeadingInset).padding(.trailing, 12)
                        .frame(height: titleBarHeight)
                        .background(WindowDragArea())
                    }
                    terminalPanel.padding(.top, model.sidebarVisible ? 8 : 0)
                        .padding(.bottom, 8).padding(.trailing, 8)
                        .padding(.leading, model.sidebarVisible ? 0 : 8)
                }
            }
            .overlay(alignment: .leading) {
                if model.sidebarVisible {
                    SidebarResizer()
                        .offset(x: sidebarWidth - 4)
                        .gesture(sidebarResizeGesture(windowWidth: geometry.size.width))
                }
            }
            .coordinateSpace(name: "desktopRoot")
        }
        .background(SidebarMaterial())
        .ignoresSafeArea()
        .foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showSettings) { settings }
    }

    private func sidebar(terminalDropArea: CGRect) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                sidebarToggle
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    sidebarModeButton(.projects, icon: "folder", label: "Group by Project")
                    sidebarModeButton(.activity, icon: "clock", label: "Sort by Recent Activity")
                }
                Menu {
                    Button("Add Project…", action: model.addProject)
                    Button("Refresh Connection", action: model.refreshConnection)
                } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Palette.muted)
            }
            .padding(.leading, titleBarLeadingInset).padding(.trailing, 12)
            .frame(height: titleBarHeight)
            .background(WindowDragArea())

            if model.conversations.count > 8 {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    TextField("Search conversations", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                }.foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.sidebarMode == .activity {
                        ForEach(model.activitySections) { section in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                                    .padding(.leading, 16).frame(height: 24)
                                    .accessibilityAddTraits(.isHeader)
                                ConversationRows(model: model, rows: section.rows, terminalDropArea: terminalDropArea, showsProject: true)
                            }
                        }
                    } else {
                        ForEach(model.projects) { project in
                            ProjectSection(model: model, project: project,
                                           terminalDropArea: terminalDropArea, draggedProjectID: $draggedProjectID)
                        }
                    }
                    if model.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.3)
                            Text("Add a folder to get started.").font(.system(size: 12))
                        }.foregroundStyle(Palette.muted).padding(.horizontal, 20).padding(.top, 16)
                    }
                }.padding(.top, 4).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
                // Rows and project headers keep their own menus; empty space offers new work.
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Project…", action: model.addProject)
                    Menu("New Session") {
                        ForEach([Harness.claude, .codex, .opencode, .agy, .shell]) { harness in
                            Button(harness.name) { model.startSession(harness: harness) }
                                .disabled(AppPaths.executable(harness.executableName) == nil)
                        }
                    }.disabled(model.busy)
                }

            HStack {
                Button(action: model.addProject) { Image(systemName: "plus").font(.system(size: 18, weight: .light)) }
                    .buttonStyle(QuietButton()).help("Add Project · ⌘O").accessibilityLabel("Add Project")
                Spacer()
                Button { model.showSettings = true } label: { Image(systemName: "gearshape.fill").font(.system(size: 14)) }
                    .buttonStyle(QuietButton()).help("Settings · ⌘,").accessibilityLabel("Settings")
            }.foregroundStyle(Palette.muted).padding(.horizontal, 12).frame(height: 42)
        }
    }

    private func effectiveSidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        let availableMaximum = max(sidebarMinWidth, Double(windowWidth) - minimumTerminalWidth)
        return CGFloat(min(max(savedSidebarWidth, sidebarMinWidth), min(sidebarMaxWidth, availableMaximum)))
    }

    private func sidebarResizeGesture(windowWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("desktopRoot"))
            .onChanged { value in
                let availableMaximum = max(sidebarMinWidth, Double(windowWidth) - minimumTerminalWidth)
                let maximum = min(sidebarMaxWidth, availableMaximum)
                savedSidebarWidth = min(maximum, max(sidebarMinWidth, Double(value.location.x)))
            }
    }

    private func sidebarModeButton(_ mode: SidebarMode, icon: String, label: String) -> some View {
        let current = model.sidebarMode == mode
        return Button {
            model.sidebarMode = mode
            model.persist()
        } label: {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 24, height: 22)
                .background(current ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(current ? Palette.text.opacity(0.9) : Palette.muted)
            .help(label).accessibilityLabel(label).accessibilityAddTraits(current ? .isSelected : [])
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { model.sidebarVisible.toggle() }
            model.persist()
        } label: { Image(systemName: "sidebar.left").font(.system(size: 15)) }
            .buttonStyle(QuietButton()).foregroundStyle(Palette.muted)
            .help("Toggle Sidebar · ⌃⌘S").accessibilityLabel("Toggle sidebar")
    }

    private var terminalPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let conversation = model.selected {
                    HarnessIcon(harness: conversation.harness).frame(width: 16, height: 16)
                    Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(Palette.text.opacity(0.9))
                    if model.isLive(conversation), conversation.status == "working" { WorkingDots().frame(width: 14, height: 14) }
                    Spacer(minLength: 15)
                    Menu {
                        Button("Rename…") { model.rename(conversation) }
                        if model.isLive(conversation) { Button("Stop Session…") { model.stop(conversation) } }
                        else if conversation.parentID != nil {
                            if conversation.status != "working" { Button("Resume in Terminal") { model.resume(conversation) } }
                        } else {
                            Button("Resume") { model.resume(conversation) }
                            Button("Remove from List") { model.forget(conversation) }
                        }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 15)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Palette.muted)
                } else {
                    Text("Herdr Desktop").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                    Spacer()
                    Circle().fill(model.connected ? Color.green.opacity(0.7) : Palette.muted.opacity(0.5)).frame(width: 5, height: 5)
                }
            }.padding(.horizontal, 14).frame(height: 38).background(WindowDragArea())

            if let conversation = model.selected {
                if model.isLive(conversation) || model.demo {
                    TerminalSurface(host: model.terminal).padding(.horizontal, 8).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversation.parentID != nil {
                    ClaudeChildTranscriptView(conversation: conversation,
                                              url: model.transcriptURL(for: conversation),
                                              resume: { model.resume(conversation) })
                } else {
                    VStack(spacing: 16) {
                        HarnessIcon(harness: conversation.harness).frame(width: 32, height: 32).opacity(0.75)
                        Text(conversation.title).font(.system(size: 21, weight: .medium)).multilineTextAlignment(.center)
                        Text("\(conversation.harness.name) · \(conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en"))))")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        if conversation.nativeID != nil || conversation.harness == .shell {
                            Button { model.resume(conversation) } label: {
                                Label(model.busy ? "Opening…" : "Resume Conversation", systemImage: "arrow.turn.down.right")
                            }.buttonStyle(AccentButton()).disabled(model.busy).padding(.top, 5)
                        } else {
                            Text("This session has not reported a resume ID yet.")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { welcome }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 13) {
                ForEach([Harness.claude, .codex, .opencode, .agy]) { harness in
                    HarnessIcon(harness: harness).frame(width: 24, height: 24)
                        .frame(width: 49, height: 49)
                        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border, lineWidth: 1))
                }
            }.padding(.bottom, 26)
            Text("Start with a project.").font(.system(size: 27, weight: .medium, design: .rounded)).tracking(-0.7)
            Text("Your conversations together. Pick up where you left off.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 10)
            if let project = model.projects.first {
                NewConversationMenu(model: model, project: project, prominent: true).padding(.top, 26)
            } else {
                Button(action: model.addProject) { Label("Add Project", systemImage: "plus") }
                    .buttonStyle(AccentButton()).padding(.top, 26)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Palette.accent.opacity(0.8)).frame(width: 4, height: 4)
                Text("Local. Simple. Right where you left off.").font(.system(size: 11))
            }.foregroundStyle(Palette.muted).padding(.bottom, 29)
        }.frame(maxWidth: .infinity)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                Text("Settings").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("Done") { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Terminal font size").font(.system(size: 13, weight: .medium))
                HStack {
                    Slider(value: $model.fontSize, in: 11...20, step: 1)
                        .onChange(of: model.fontSize) { _, value in model.terminal.fontSize = value; model.persist() }
                    Text("\(Int(model.fontSize)) pt").font(.system(size: 12, design: .monospaced)).frame(width: 45)
                }
            }
            VStack(spacing: 13) {
                ForEach([Harness.claude, .codex, .opencode, .agy]) { harness in
                    HStack {
                        HarnessIcon(harness: harness).frame(width: 17, height: 17)
                        Text(harness.name).font(.system(size: 13))
                        Spacer()
                        Text(AppPaths.executable(harness.executableName) == nil ? "Not installed" : "Installed")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Text("Closing the window keeps sessions running. Quitting the app stops its processes; saved conversations resume when you open them.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: 390).background(Palette.panel).preferredColorScheme(.dark)
    }
}

private struct ProjectSection: View {
    @ObservedObject var model: AppModel
    let project: ProjectRecord
    let terminalDropArea: CGRect
    @Binding var draggedProjectID: String?
    @StoredState<Bool> private var hover = false
    var body: some View {
        VStack(spacing: 3) {
            // The folder sits in the rows' status column so project and conversation titles align.
            HStack(spacing: 8) {
                // A tap gesture rather than a Button: a Button swallows the drag that reorders projects.
                HStack(spacing: 7) {
                    Image(systemName: project.isSessions ? "bubble.left.and.bubble.right" : project.collapsed ? "folder" : "folder.fill").font(.system(size: project.isSessions ? 10 : 12))
                        .foregroundStyle(Palette.muted).frame(width: 13)
                    Text(project.name).font(.system(size: 13)).foregroundStyle(Palette.text.opacity(0.9)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
                    .onTapGesture { model.toggleProject(project) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default) { model.toggleProject(project) }
                NewConversationMenu(model: model, project: project).foregroundStyle(Palette.muted)
                    .opacity(hover ? 0.8 : 0)
            }.padding(.leading, 16).padding(.trailing, 18).frame(height: 28)
                .onHover { hover = $0 }
                .onDrag {
                    draggedProjectID = project.id
                    let provider = NSItemProvider()
                    // A standard type matches the drop target; process-only visibility keeps it out of Finder and the terminal.
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess) { load in
                        load(Data(project.id.utf8), nil); return nil
                    }
                    return provider
                }
                .onDrop(of: [.utf8PlainText], delegate: ProjectDropDelegate(target: project.id, model: model, dragged: $draggedProjectID))
                .contextMenu {
                    if !project.isSessions {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                    }
                    if model.rows(for: project).isEmpty { Button(project.isSessions ? "Hide Sessions" : "Remove Project") { model.removeProject(project) } }
                }
            if !project.collapsed || !model.search.isEmpty {
                let rows = model.rows(for: project)
                ConversationRows(model: model, rows: rows, terminalDropArea: terminalDropArea)
                if rows.isEmpty && model.search.isEmpty {
                    // Borderless menus ignore foregroundStyle on their label, so dim the whole control.
                    NewConversationMenu(model: model, project: project, showText: true).opacity(0.55)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16).padding(.vertical, 4)
                }
            }
        }
    }
}

/// Conversations with their child tasks nested beneath; shared by both sidebar modes.
private struct ConversationRows: View {
    @ObservedObject var model: AppModel
    let rows: [LiveSession]
    let terminalDropArea: CGRect
    var showsProject = false
    var body: some View {
        ForEach(rows) { conversation in
            let children = model.children(of: conversation)
            sessionItem(conversation, childCount: children.count,
                        workingChildren: children.filter { $0.status == "working" }.count,
                        unreadChildren: children.filter(\.unread).count)
            if !children.isEmpty && (model.expandedTaskIDs.contains(conversation.id) || !model.search.isEmpty) {
                ForEach(children.filter { model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search) }) { child in
                    // Child status glyphs line up under the parent's title.
                    sessionItem(child).padding(.leading, 20)
                }
            }
        }
    }

    private func sessionItem(_ conversation: LiveSession, childCount: Int = 0, workingChildren: Int = 0, unreadChildren: Int = 0) -> some View {
        let transcriptURL = model.transcriptURL(for: conversation)
        return SessionRow(conversation: conversation, selected: model.selectedID == conversation.id,
                          live: model.isLive(conversation), transcriptURL: transcriptURL,
                          projectName: showsProject && conversation.parentID == nil ? model.projectName(for: conversation) : nil,
                          branch: model.branches[conversation.projectID],
                          childCount: childCount, workingChildren: workingChildren, unreadChildren: unreadChildren,
                          expanded: model.expandedTaskIDs.contains(conversation.id),
                          terminalDropArea: terminalDropArea,
                          action: { model.open(conversation) },
                          toggleChildren: { model.toggleChildren(of: conversation) },
                          copyPath: { model.copyTranscriptPath(for: conversation) },
                          dropPath: { url in
                              guard let target = model.selected, model.isLive(target) else { return }
                              model.terminal.pasteTranscriptPath(url.path, into: target.terminalID)
                          })
            .contextMenu {
                if transcriptURL != nil {
                    Button("Copy Conversation Path") { model.copyTranscriptPath(for: conversation) }
                    Divider()
                }
                Button("Rename…") { model.rename(conversation) }
                if model.isLive(conversation) { Button("Stop Session…") { model.stop(conversation) } }
                else if conversation.parentID != nil && conversation.status != "working" {
                    Button("Resume in Terminal") { model.resume(conversation) }
                }
                if conversation.parentID == nil || conversation.status != "working" || model.isLive(conversation) {
                    Divider()
                    Button("Delete Session…", role: .destructive) { model.delete(conversation) }
                    if SessionHistoryDeleter.supports(conversation) {
                        Button("Delete Permanently…", role: .destructive) { model.deletePermanently(conversation) }
                    } else if conversation.harness == .agy, conversation.nativeID != nil {
                        Button("Delete in Antigravity…") { model.showAntigravityDeletionInstructions(conversation) }
                    }
                }
            }
    }
}

private struct SessionRow: View {
    let conversation: LiveSession
    let selected: Bool
    let live: Bool
    let transcriptURL: URL?
    let projectName: String?
    let branch: String?
    let childCount: Int
    let workingChildren: Int
    let unreadChildren: Int
    let expanded: Bool
    let terminalDropArea: CGRect
    let action: () -> Void
    let toggleChildren: () -> Void
    let copyPath: () -> Void
    let dropPath: (URL) -> Void
    @StoredState<Bool> private var hover = false
    @StoredState<Bool> private var dragging = false
    @ViewBuilder
    var body: some View {
        if let transcriptURL {
            row.gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { result in
                switch result {
                case .first: copyPath()
                case .second: action()
                }
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 7, coordinateSpace: .named("desktopRoot"))
                    .onChanged { _ in dragging = true }
                    .onEnded { value in
                        dragging = false
                        guard terminalDropArea.contains(value.location) else { return }
                        dropPath(transcriptURL)
                    }
            )
            .opacity(dragging ? 0.6 : 1)
            .help("Drag to a terminal · Double-click to copy the conversation path")
        } else {
            row.onTapGesture(perform: action)
        }
    }

    /// Top-level conversations are two-line cards; child tasks stay compact under their parent.
    private var isCard: Bool { conversation.parentID == nil }

    private var row: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            if isCard {
                // Starts under the title, clear of the status column.
                HStack(spacing: 4) {
                    if let branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let projectName {
                        // The project label is short and keeps its place; a long branch truncates first.
                        Text(projectName).lineLimit(1).frame(maxWidth: 120, alignment: .trailing).layoutPriority(1)
                    }
                    HarnessIcon(harness: conversation.harness).frame(width: 13, height: 13)
                        .opacity(selected ? 0.95 : 0.6).padding(.leading, 2)
                }.font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(.leading, 20)
            }
        }.padding(.leading, 8).padding(.trailing, 10)
            .padding(.vertical, isCard ? 8 : 0).frame(minHeight: 28)
            .background(selected ? Color.white.opacity(0.08) : hover ? Color.white.opacity(0.035) : .clear,
                        in: RoundedRectangle(cornerRadius: isCard ? 9 : 7))
            .overlay(RoundedRectangle(cornerRadius: isCard ? 9 : 7).strokeBorder(selected ? Color.white.opacity(0.07) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .padding(.horizontal, 8).onHover { hover = $0 }
            .help([conversation.title, projectName, branch, conversation.harness.name].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(conversation.title), \([projectName, branch.map { "branch \($0)" }].compactMap { $0 }.map { "\($0), " }.joined())\(conversation.harness.name), \(live || conversation.status == "working" ? "active" : "history")\(conversation.unread ? ", finished" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    private var titleLine: some View {
        HStack(spacing: 7) {
            Group {
                if conversation.status == "working" && (live || conversation.parentID != nil) { WorkingDots() }
                else if live && conversation.status == "blocked" { Circle().fill(Color.orange.opacity(0.85)).frame(width: 5, height: 5) }
                else if conversation.unread { Circle().fill(Palette.unread).frame(width: 5, height: 5) }
                else { Color.clear }
            }.frame(width: 13, height: 13)
            Text(conversation.title).font(.system(size: isCard ? 13.5 : 13, weight: selected ? .medium : .regular))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(live || selected || conversation.unread || conversation.status == "working" ? Palette.text : Palette.muted.opacity(1.35))
            Spacer(minLength: 3)
            if childCount > 0 {
                Button(action: toggleChildren) {
                    HStack(spacing: 4) {
                        if workingChildren > 0 { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
                        else if unreadChildren > 0 { Circle().fill(Palette.unread).frame(width: 5, height: 5) }
                        Text("\(childCount)").font(.system(size: 10, weight: .medium))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(workingChildren > 0 ? Palette.accent : Palette.muted)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(Color.white.opacity(hover || expanded ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(expanded ? "Hide child tasks" : "Show child tasks")
            }
            if isCard {
                TimelineView(.everyMinute) { context in
                    Text(RelativeAge.label(since: conversation.updatedAt, now: context.date))
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted).fixedSize()
                }
            } else {
                HarnessIcon(harness: conversation.harness).frame(width: 14, height: 14)
                    .opacity(selected ? 0.95 : 0.55)
            }
        }.frame(height: isCard ? 18 : 28)
    }
}

private struct ClaudeChildTranscriptView: View {
    let conversation: LiveSession
    let url: URL?
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(conversation.status == "working" ? "Background task running" : "Background task finished")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if conversation.status != "working" {
                    Button("Resume in Terminal", action: resume).buttonStyle(AccentButton())
                }
            }.padding(.horizontal, 16).padding(.top, 10)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                ScrollView {
                    Text(url.map(ClaudeChildTranscript.display(at:)) ?? "The Claude transcript is not available yet.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
        }
    }
}

struct NewConversationMenu: View {
    @ObservedObject var model: AppModel
    let project: ProjectRecord
    var showText = false
    var prominent = false
    var body: some View {
        Menu {
            ForEach([Harness.claude, .codex, .opencode, .agy, .shell]) { harness in
                Button(harness.name) { model.start(project: project, harness: harness) }
                    .disabled(AppPaths.executable(harness.executableName) == nil)
            }
        } label: {
            if prominent { Label(model.busy ? "Opening…" : "New Conversation", systemImage: "plus").padding(.horizontal, 15).padding(.vertical, 10)
                    .background(Palette.accent.opacity(0.17), in: RoundedRectangle(cornerRadius: 8)) }
            else if showText { Label("New Conversation", systemImage: "plus").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            else { Image(systemName: "plus").font(.system(size: 12)) }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy).help("New conversation in \(project.name)")
    }
}

struct HarnessIcon: View {
    let harness: Harness

    // Load loose SwiftPM image resources once; SwiftUI's named-image lookup expects asset catalogs.
    private static let images: [Harness: NSImage] = Dictionary(uniqueKeysWithValues:
        Harness.allCases.filter { $0 != .shell }.map { harness in
            guard let url = Bundle.module.url(forResource: "harness-\(harness.rawValue)", withExtension: "png"),
                  let image = NSImage(contentsOf: url) else {
                preconditionFailure("Missing bundled artwork for \(harness.rawValue)")
            }
            return (harness, image.croppingTransparentPadding())
        }
    )

    var body: some View {
        Group {
            if harness == .shell {
                Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(Palette.muted)
            } else {
                Image(nsImage: Self.images[harness]!)
                    .resizable().interpolation(.high).scaledToFit()
            }
        }.help(harness.name).accessibilityLabel(harness.name)
    }
}

private extension NSImage {
    func croppingTransparentPadding() -> NSImage {
        guard let data = tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let cgImage = bitmap.cgImage else { return self }
        var left = bitmap.pixelsWide
        var top = bitmap.pixelsHigh
        var right = -1
        var bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top,
              let cropped = cgImage.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else {
            return self
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

/// Reorders live while a project header is dragged over another one.
private struct ProjectDropDelegate: DropDelegate {
    let target: String
    let model: AppModel
    @Binding var dragged: String?
    func validateDrop(info: DropInfo) -> Bool { dragged != nil }
    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) { model.moveProject(dragged, onto: target) }
        model.persist()
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}

/// Translucent window background: Liquid Glass on macOS 26+, the sidebar material before.
/// Both are composited by the system, follow Reduce Transparency, and redraw only on change.
/// Glass takes on the brightness of what is behind the window and its `tintColor` does not
/// darken it, so a separate dark layer keeps the navy character over light apps.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.086, alpha: 0.75).cgColor
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = tint
            return glass
        }
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SidebarResizer: View {
    @StoredState<Bool> private var hover = false
    var body: some View {
        Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
            .overlay {
                Capsule().fill(Palette.border.opacity(hover ? 1 : 0.55)).frame(width: 2, height: 28)
            }
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hover { NSCursor.pop() } }
            .accessibilityLabel("Resize sidebar")
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let host: TerminalHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 24, height: 25).contentShape(Rectangle()).opacity(configuration.isPressed ? 0.5 : 1)
    }
}

private struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(Palette.text).background(Palette.accent.opacity(configuration.isPressed ? 0.27 : 0.16), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.accent.opacity(0.25), lineWidth: 1))
    }
}
