import AppKit
import SwiftUI

/// The browser's Workshop tab (left side): search, sort and filters over the public Steam Workshop pages, a grid of
/// results, paging, the steamcmd download queue and the login notice.
struct WorkshopBrowser: View {
    @ObservedObject var state: AppState
    @ObservedObject var workshop: WorkshopController
    @ObservedObject var queue: DownloadQueue
    @Binding var selection: WorkshopItem?
    @State private var searchText = ""

    init(state: AppState, selection: Binding<WorkshopItem?>) {
        self.state = state
        workshop = state.workshop
        queue = state.workshop.queue
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = queue.loginProblem { LoginNotice(message: problem, workshop: workshop) }
            if workshop.username.trimmingCharacters(in: .whitespaces).isEmpty || workshop.steamcmdExecutable == nil {
                SetupNotice(hasUser: !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty,
                            hasSteamcmd: workshop.steamcmdExecutable != nil, workshop: workshop)
            }
            results
            if !queue.jobs.isEmpty {
                Divider()
                DownloadList(queue: queue)
            }
            Divider()
            pager
        }
        .onAppear {
            searchText = workshop.query.searchText
            if workshop.page == nil && !workshop.loading { workshop.search() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the Workshop", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit { workshop.query.searchText = searchText; workshop.search() }
            Picker("Sort", selection: Binding(get: { workshop.query.sort }, set: { workshop.query.sort = $0; workshop.search() })) {
                ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Type", selection: Binding(get: { workshop.query.type ?? "" }, set: {
                workshop.query.type = $0.isEmpty ? nil : $0
                workshop.search()
            })) {
                Text("All types").tag("")
                ForEach(WorkshopCatalog.types, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu(workshop.query.tags.isEmpty ? "Tags" : "Tags (\(workshop.query.tags.count))") {
                ForEach(WorkshopCatalog.filterTags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { workshop.query.tags.contains(tag) }, set: { on in
                        if on { workshop.query.tags.append(tag) } else { workshop.query.tags.removeAll { $0 == tag } }
                        workshop.search()
                    }))
                }
                if !workshop.query.tags.isEmpty {
                    Divider()
                    Button("Clear tags") { workshop.query.tags = []; workshop.search() }
                }
            }
            .fixedSize()
            Button { workshop.search(keepPage: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload this page")
        }
        .padding(10)
    }

    @ViewBuilder private var results: some View {
        let items = workshop.visibleItems
        ZStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        WorkshopTile(item: item, status: workshop.status(of: item), selected: selection?.id == item.id)
                            .onTapGesture { selection = item }
                    }
                }
                .padding(12)
            }
            if workshop.loading && items.isEmpty {
                ProgressView()
            } else if let error = workshop.error {
                VStack(spacing: 8) {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Button("Try again") { workshop.search(keepPage: true) }
                }
            } else if !workshop.loading && workshop.page != nil && items.isEmpty {
                Text("Nothing found").foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var pager: some View {
        HStack {
            Button { workshop.goToPage(workshop.query.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(workshop.query.page <= 1 || workshop.loading)
            if let page = workshop.page {
                Text("Page \(page.page) of \(page.totalPages) · \(page.totalCount.formatted()) items")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { workshop.goToPage(workshop.query.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(workshop.loading || (workshop.page.map { $0.page >= $0.totalPages } ?? true))
            if workshop.loading { ProgressView().controlSize(.small) }
            Spacer()
            Text(workshop.rating.label).font(.caption).foregroundStyle(.secondary)
                .help("Age ratings shown; change in Settings")
        }
        .padding(6)
    }
}

/// The browser's Subscribed tab (left side): the account's Workshop subscriptions as the Steam client last recorded
/// them on this Mac (`SteamSubscriptions`), newest first, with local filters and Download All.
struct SubscribedBrowser: View {
    @ObservedObject var state: AppState
    @ObservedObject var workshop: WorkshopController
    @ObservedObject var queue: DownloadQueue
    @Binding var selection: WorkshopItem?
    @State private var message: String?

    init(state: AppState, selection: Binding<WorkshopItem?>) {
        self.state = state
        workshop = state.workshop
        queue = state.workshop.queue
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = queue.loginProblem { LoginNotice(message: problem, workshop: workshop) }
            if workshop.username.trimmingCharacters(in: .whitespaces).isEmpty || workshop.steamcmdExecutable == nil {
                SetupNotice(hasUser: !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty,
                            hasSteamcmd: workshop.steamcmdExecutable != nil, workshop: workshop)
            }
            summary
            Divider()
            results
            if !queue.jobs.isEmpty {
                Divider()
                DownloadList(queue: queue)
            }
        }
        .onAppear {
            guard workshop.subscriptionSnapshot == nil && !workshop.subscribedLoading else { return }
            workshop.loadSubscribed()
            // Once per launch, ask Steam for the current list when downloading is set up.
            if workshop.subscriptionSyncStatus == nil && canAskSteam { workshop.refreshSubscriptionsFromSteam() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search subscriptions", text: $workshop.subscribedFilter.searchText)
                .textFieldStyle(.plain)
            Picker("Type", selection: $workshop.subscribedFilter.type) {
                Text("All types").tag(String?.none)
                ForEach(WorkshopCatalog.types, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Not downloaded", isOn: $workshop.subscribedFilter.missingOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
            Button {
                message = workshop.refreshSubscriptionsFromSteam()
            } label: {
                Label("Refresh from Steam", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(workshop.subscriptionSyncRunning || !canAskSteam)
            .help(canAskSteam ? "Fetch your current subscriptions from Steam with steamcmd"
                  : "Needs steamcmd and your Steam username (Settings)")
        }
        .padding(10)
    }

    private var canAskSteam: Bool {
        !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && workshop.steamcmdExecutable != nil
    }

    private var summary: some View {
        let missing = workshop.missingSubscribedCount
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(counts).font(.caption)
                if let status = workshop.subscriptionSyncStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
                if let snap = workshop.subscriptionSnapshot, snap.lastUpdated > 0 {
                    Text("List from "
                         + Date(timeIntervalSince1970: TimeInterval(snap.lastUpdated)).formatted(date: .abbreviated, time: .shortened)
                         + (canAskSteam ? "" : ". Set up downloading in Settings to refresh it from Steam."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption2).foregroundStyle(.red) }
            }
            Spacer()
            if workshop.subscribedLoading || workshop.subscriptionSyncRunning { ProgressView().controlSize(.small) }
            Button(missing > 0 ? "Download All (\(missing))" : "Download All") {
                let r = workshop.downloadMissingSubscribed()
                message = r.problem
            }
            .disabled(missing == 0)
            .help("Download every subscription shown here that isn't downloaded yet")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var counts: String {
        var parts = ["\(workshop.subscribed.count) subscribed"]
        let downloaded = workshop.subscribed.filter { if case .installed = workshop.status(of: $0) { return true } else { return false } }.count
        parts.append("\(downloaded) downloaded")
        if workshop.subscribedFilteredOut > 0 { parts.append("\(workshop.subscribedFilteredOut) hidden by the age filter or blocklist") }
        if workshop.subscribedUnavailable > 0 { parts.append("\(workshop.subscribedUnavailable) no longer on the Workshop") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var results: some View {
        let items = workshop.visibleSubscribed
        ZStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        WorkshopTile(item: item, status: workshop.status(of: item), selected: selection?.id == item.id)
                            .onTapGesture { selection = item }
                    }
                }
                .padding(12)
            }
            if workshop.subscribedLoading && items.isEmpty {
                ProgressView()
            } else if let error = workshop.subscribedError, items.isEmpty {
                VStack(spacing: 8) {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Button("Try again") { workshop.loadSubscribed() }
                }
            } else if let snap = workshop.subscriptionSnapshot, snap.files.isEmpty {
                VStack(spacing: 6) {
                    Text("No subscription list found").font(.headline)
                    Text("Refresh from Steam fetches it with steamcmd (set your username in Settings first).")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            } else if !workshop.subscribedLoading && items.isEmpty {
                Text(workshop.subscribed.isEmpty ? "No Wallpaper Engine subscriptions" : "Nothing matches the filters")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct WorkshopTile: View {
    let item: WorkshopItem
    let status: WorkshopController.ItemStatus
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkshopThumbnail(item: item)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) { badge.padding(5) }
                .overlay(alignment: .bottom) {
                    if case .downloading(_, let p) = status {
                        ProgressView(value: p ?? 0).progressViewStyle(.linear).padding(6)
                    }
                }
                .opacity(item.unsupportedReason == nil ? 1 : 0.45)
            Text(item.title).font(.caption).lineLimit(2, reservesSpace: true)
            Text(([item.type.isEmpty ? "Unknown type" : item.type] + item.displayTags.prefix(2)).joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(item.unsupportedReason ?? item.title)
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .installed(let update):
            Image(systemName: update ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, update ? Color.orange : Color.green)
                .font(.title3)
                .help(update ? "Downloaded; an update is available" : "Downloaded")
        case .queued:
            Image(systemName: "clock.fill").foregroundStyle(.white).shadow(radius: 2)
        case .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(.white).shadow(radius: 2)
        case .notInstalled:
            if item.unsupportedReason != nil {
                Image(systemName: "nosign").foregroundStyle(.white).shadow(radius: 2)
            }
        }
    }
}

/// A Workshop preview: downloaded to the disk cache, then decoded like library previews.
struct WorkshopThumbnail: View {
    let item: WorkshopItem
    var size = 320
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .onAppear(perform: load)
        .onChange(of: item.id) { _, _ in image = nil; load() }
    }

    private func load() {
        guard image == nil else { return }
        let id = item.id
        WorkshopPreviewCache.shared.preview(item, size: size) { file in
            guard let file, id == item.id else { return }
            ThumbnailCache.shared.image(file, maxPixels: size * 2) { image = $0 }
        }
    }
}

/// The selected Workshop item (right side): details, Download / Update / Remove.
struct WorkshopDetail: View {
    @ObservedObject var state: AppState
    @ObservedObject var workshop: WorkshopController
    let item: WorkshopItem
    var showInLibrary: (String) -> Void
    @State private var confirmRemove = false
    @State private var message: String?

    init(state: AppState, item: WorkshopItem, showInLibrary: @escaping (String) -> Void) {
        self.state = state
        workshop = state.workshop
        self.item = item
        self.showInLibrary = showInLibrary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WorkshopThumbnail(item: item, size: 640)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.title).font(.headline).textSelection(.enabled)
                Text("\(item.type.isEmpty ? "Unknown type" : item.type) · \(item.rating ?? "Unrated") · \(item.id)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(facts).font(.caption).foregroundStyle(.secondary)
                if !item.displayTags.isEmpty {
                    Text(item.displayTags.joined(separator: ", ")).font(.caption)
                }
                if let reason = item.unsupportedReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                actions
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                if let job = workshop.queue.job(item.id) {
                    jobStatus(job)
                }
                if !item.description.isEmpty {
                    Divider()
                    Text(item.description).font(.caption).textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .alert("Remove “\(item.title)”?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                do { try workshop.remove(item.id) } catch { message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folder is deleted from disk" + (state.activeIDs.contains(item.id) ? ", and it stops showing on the desktop." : ".")
                 + " You can download it again later.")
        }
    }

    private var facts: String {
        var parts: [String] = []
        if item.fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)) }
        parts.append("\(item.subscriptions.formatted()) subscribers")
        if item.timeUpdated > 0 {
            parts.append("updated " + Date(timeIntervalSince1970: TimeInterval(item.timeUpdated)).formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let status = workshop.status(of: item)
        HStack {
            switch status {
            case .notInstalled:
                Button("Download") { message = workshop.download(item) }
                    .keyboardShortcut(.defaultAction)
            case .installed(let update):
                if state.item(item.id) != nil {
                    Button("Show in Library") { showInLibrary(item.id) }
                }
                if update {
                    Button("Update") { message = workshop.download(item, update: true) }
                } else {
                    Button("Download Again") { message = workshop.download(item, update: true) }
                        .help("Re-download with steamcmd")
                }
                if workshop.canRemove(item.id) {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
            case .queued, .downloading:
                Button("Cancel") { workshop.queue.cancel(item.id) }
            }
            Spacer()
            Button {
                if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "safari") }
            .help("Open the Workshop page")
        }
    }

    @ViewBuilder private func jobStatus(_ job: DownloadQueue.Job) -> some View {
        switch job.phase {
        case .running(let s):
            VStack(alignment: .leading, spacing: 4) {
                Text(s).font(.caption)
                if let p = job.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
            }
        case .failed(let r):
            Label(r, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        case .needsLogin:
            Label("Steam login needed (see the notice on the left)", systemImage: "person.badge.key").font(.caption).foregroundStyle(.orange)
        case .succeeded:
            Label("Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .queued:
            Label("Queued", systemImage: "clock").font(.caption)
        case .cancelled:
            EmptyView()
        }
    }
}

/// steamcmd has no saved login: sign in from here.
private struct LoginNotice: View {
    let message: String
    @ObservedObject var workshop: WorkshopController
    @State private var signingIn = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.badge.key").font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Steam sign-in needed").font(.headline)
                Text("steamcmd has no saved Steam login, so downloads are paused. Sign in once and they continue.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Sign In…") { signingIn = true }
            Button("Retry") { workshop.queue.retry() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .help(message)
        .sheet(isPresented: $signingIn) { SteamSignInSheet(workshop: workshop) }
    }
}

private struct SetupNotice: View {
    let hasUser: Bool
    let hasSteamcmd: Bool
    var workshop: WorkshopController? = nil
    @State private var settingUp = false

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle")
            VStack(alignment: .leading, spacing: 2) {
                if !hasSteamcmd { Text("Downloading needs steamcmd, Valve's command-line Steam. photon can set it up.") }
                if !hasUser { Text("Set your Steam username to download. Browsing works without it.") }
            }
            .font(.caption)
            Spacer()
            if let workshop {
                Button(hasSteamcmd ? "Sign In…" : "Set Up…") { settingUp = true }
                    .sheet(isPresented: $settingUp) { SteamSignInSheet(workshop: workshop) }
            }
            Button("Settings…") { NSApp.sendAction(Selector(("showSettings")), to: nil, from: nil) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }
}

private struct DownloadList: View {
    @ObservedObject var queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Downloads").font(.caption.bold())
                Spacer()
                if queue.jobs.contains(where: { $0.phase.isFinished }) {
                    Button("Clear finished") { queue.clearFinished() }.buttonStyle(.link).font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(queue.jobs) { job in
                        HStack(spacing: 6) {
                            Text(job.title).lineLimit(1)
                            if job.dependencyOf != nil { Text("(dependency)").foregroundStyle(.secondary) }
                            Spacer()
                            if case .running = job.phase, let p = job.progress {
                                ProgressView(value: p).frame(width: 80)
                            }
                            Text(job.phase.label).foregroundStyle(color(job.phase)).lineLimit(1)
                                .help(job.phase.label)
                            if !job.phase.isFinished {
                                Button { queue.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 90)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func color(_ p: DownloadQueue.Phase) -> Color {
        switch p {
        case .failed: return .red
        case .needsLogin: return .orange
        case .succeeded: return .green
        default: return .secondary
        }
    }
}

/// Settings → Steam Workshop.
struct WorkshopSettingsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var workshop: WorkshopController
    @State private var signingIn = false

    init(state: AppState) {
        self.state = state
        workshop = state.workshop
    }

    var body: some View {
        Section("Steam Workshop") {
            TextField("Steam username", text: $workshop.username)
                .textContentType(.username)
                .autocorrectionDisabled()
            HStack {
                Text("Only the account name is stored. steamcmd keeps its own login after you sign in once; your password "
                     + "and Steam Guard code go only to steamcmd.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(workshop.steamcmdExecutable == nil ? "Set Up steamcmd…" : "Sign In…") { signingIn = true }
                    .sheet(isPresented: $signingIn) { SteamSignInSheet(workshop: workshop) }
            }
            TextField("steamcmd path", text: $workshop.steamcmdPath, prompt: Text("Automatic"))
            Text(workshop.steamcmdExecutable.map { "Using \($0)" } ?? "steamcmd isn't set up. Use Set Up steamcmd above, or install it with: brew install --cask steamcmd")
                .font(.caption).foregroundStyle(workshop.steamcmdExecutable == nil ? .orange : .secondary)
            Picker("Age ratings shown", selection: $workshop.rating) {
                ForEach(WorkshopRatingFilter.allCases) { Text($0.label).tag($0) }
            }
            Text("Downloads go to \(workshop.downloadDirectory.path). "
                 + (state.hiddenIDs.isEmpty ? "" : "\(state.hiddenIDs.count) item(s) are hidden by \(state.hiddenFile?.path ?? "the blocklist")."))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
