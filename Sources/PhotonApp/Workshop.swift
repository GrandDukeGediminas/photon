import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Steam Workshop item of Wallpaper Engine (app 431960), from a browse page or `GetPublishedFileDetails`.
package struct WorkshopItem: Identifiable, Hashable, Codable {
    package let id: String
    package var title: String
    package var previewURL: URL?
    package var tags: [String]
    package var fileSize: Int64
    package var subscriptions: Int
    package var timeUpdated: Int
    package var timeCreated: Int
    package var description: String
    /// The app the item belongs to (`consumer_app_id`), when the source says.
    package var appID: Int?

    package init(id: String, title: String, previewURL: URL? = nil, tags: [String] = [], fileSize: Int64 = 0,
                 subscriptions: Int = 0, timeUpdated: Int = 0, timeCreated: Int = 0, description: String = "",
                 appID: Int? = nil) {
        self.id = id; self.title = title; self.previewURL = previewURL; self.tags = tags; self.fileSize = fileSize
        self.subscriptions = subscriptions; self.timeUpdated = timeUpdated; self.timeCreated = timeCreated
        self.description = description; self.appID = appID
    }

    /// The type tag ("Scene", "Video", "Web", "Application"), or "" when the item has none.
    package var type: String { tags.first { WorkshopCatalog.types.contains($0) } ?? "" }

    /// The age-rating tag ("Everyone", "Questionable", "Mature"), or nil.
    package var rating: String? { tags.first { WorkshopCatalog.ratings.contains($0) } }

    /// Tags other than the type and the rating, for display.
    package var displayTags: [String] {
        tags.filter { !WorkshopCatalog.types.contains($0) && !WorkshopCatalog.ratings.contains($0) && $0 != "Wallpaper" }
    }

    /// Why photon can't show this item, or nil (the library repeats the check on project.json after download).
    package var unsupportedReason: String? {
        switch type {
        case "Scene", "Video", "Web": return nil
        case "Application": return "Application wallpapers aren't supported"
        default: return tags.contains("Asset Pack") ? "Asset packs aren't wallpapers" : nil
        }
    }

    /// The preview through Steam's image CDN resizer (`imw`/`imh`), so grid thumbnails are small downloads.
    package func thumbnailURL(size: Int = 320) -> URL? {
        guard let previewURL, var c = URLComponents(url: previewURL, resolvingAgainstBaseURL: false) else { return previewURL }
        guard c.host?.hasSuffix("steamusercontent.com") == true else { return previewURL }
        c.queryItems = [URLQueryItem(name: "imw", value: "\(size)"), URLQueryItem(name: "imh", value: "\(size)"),
                        URLQueryItem(name: "ima", value: "fit"), URLQueryItem(name: "impolicy", value: "Letterbox"),
                        URLQueryItem(name: "imcolor", value: "#000000"), URLQueryItem(name: "letterbox", value: "true")]
        return c.url ?? previewURL
    }
}

/// The app's Workshop tags (the browse page's declared tags for 431960, "Type" / "Age Rating" / "Genre" / "Miscellaneous").
package enum WorkshopCatalog {
    package static let types = ["Scene", "Video", "Web", "Application"]
    package static let ratings = ["Everyone", "Questionable", "Mature"]
    package static let genres = ["Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
                                 "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing", "Retro",
                                 "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified"]
    package static let misc = ["Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR", "Media Integration",
                               "Video Texture"]
    package static var filterTags: [String] { genres + misc }
}

/// Which age ratings the Workshop shows. The default shows "Everyone" items only.
package enum WorkshopRatingFilter: String, CaseIterable, Identifiable {
    case everyone, questionable, all
    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .everyone: return "Everyone only"
        case .questionable: return "Everyone and Questionable"
        case .all: return "All, including Mature"
        }
    }

    /// Rating tags the browse request excludes.
    package var excludedTags: [String] {
        switch self {
        case .everyone: return ["Questionable", "Mature"]
        case .questionable: return ["Mature"]
        case .all: return []
        }
    }

    package func allows(_ item: WorkshopItem) -> Bool {
        guard let r = item.rating else { return true }
        return !excludedTags.contains(r)
    }
}

package enum WorkshopSort: String, CaseIterable, Identifiable {
    case trend, mostrecent, lastupdated, toprated, totaluniquesubscribers
    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .trend: return "Trending"
        case .mostrecent: return "Most recent"
        case .lastupdated: return "Last updated"
        case .toprated: return "Top rated"
        case .totaluniquesubscribers: return "Most subscribed"
        }
    }
}

/// A Workshop browse request: `https://steamcommunity.com/workshop/browse/?appid=431960&…`.
package struct WorkshopQuery: Equatable {
    package var searchText = ""
    package var sort: WorkshopSort = .trend
    /// "Scene", "Video", "Web", "Application", or nil for every type.
    package var type: String?
    /// Required tags (all must match).
    package var tags: [String] = []
    package var rating: WorkshopRatingFilter = .everyone
    package var page = 1
    /// The trending window in days.
    package var trendDays = 7

    package init(searchText: String = "", sort: WorkshopSort = .trend, type: String? = nil, tags: [String] = [],
                 rating: WorkshopRatingFilter = .everyone, page: Int = 1) {
        self.searchText = searchText; self.sort = sort; self.type = type; self.tags = tags; self.rating = rating; self.page = page
    }

    package var url: URL {
        var c = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var q = [URLQueryItem(name: "appid", value: WorkshopPaths.appID),
                 URLQueryItem(name: "browsesort", value: sort.rawValue),
                 URLQueryItem(name: "actualsort", value: sort.rawValue),
                 URLQueryItem(name: "section", value: "readytouseitems")]
        if sort == .trend { q.append(URLQueryItem(name: "days", value: "\(trendDays)")) }
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { q.append(URLQueryItem(name: "searchtext", value: text)) }
        for t in ([type].compactMap { $0 } + tags) { q.append(URLQueryItem(name: "requiredtags[]", value: t)) }
        for t in rating.excludedTags { q.append(URLQueryItem(name: "excludedtags[]", value: t)) }
        q.append(URLQueryItem(name: "p", value: "\(max(page, 1))"))
        c.queryItems = q
        // URLComponents leaves `[]` and `+` alone; Steam wants them encoded.
        c.percentEncodedQuery = c.percentEncodedQuery?
            .replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            .replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}

/// One page of browse results.
package struct WorkshopPage: Equatable {
    package var items: [WorkshopItem]
    package var page: Int
    package var totalPages: Int
    package var totalCount: Int

    package init(items: [WorkshopItem], page: Int, totalPages: Int, totalCount: Int) {
        self.items = items; self.page = page; self.totalPages = totalPages; self.totalCount = totalCount
    }
}

/// Parsing of the public browse pages and of `ISteamRemoteStorage/GetPublishedFileDetails` (neither needs an API key).
package enum WorkshopParser {
    /// A browse page. The current pages embed their data as JSON (`<script id="valve-ssr-data">` → `renderContext.queryData`
    /// → the `workshop_browse` query: `results`, `current_page`, `total_pages`, `total_count`). Without that (an older
    /// page layout) the item ids come from the item links and the details must be fetched: `items` is then empty and
    /// `ids(inBrowsePage:)` lists them.
    package static func browsePage(_ html: String) -> WorkshopPage? {
        guard let json = ssrJSON(html),
              let render = json["renderContext"] as? [String: Any],
              let qdText = render["queryData"] as? String,
              let qd = (try? JSONSerialization.jsonObject(with: Data(qdText.utf8))) as? [String: Any],
              let queries = qd["queries"] as? [[String: Any]] else { return nil }
        for q in queries {
            guard let key = q["queryKey"] as? [Any], (key.first as? String) == "workshop_browse",
                  let data = (q["state"] as? [String: Any])?["data"] as? [String: Any],
                  let results = data["results"] as? [[String: Any]] else { continue }
            return WorkshopPage(items: results.compactMap(item), page: int(data["current_page"]) ?? 1,
                                totalPages: int(data["total_pages"]) ?? 1, totalCount: int(data["total_count"]) ?? results.count)
        }
        return nil
    }

    /// The ids an older browse page links to (`sharedfiles/filedetails/?id=…`), in page order, without repeats.
    package static func ids(inBrowsePage html: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"filedetails/\?id=([0-9]+)"#)
        let ns = html as NSString
        for m in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// The page count of an older browse page: the largest `p=` page link, at least 1.
    package static func legacyPageCount(_ html: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: #"[?&]p=([0-9]+)"#)
        let ns = html as NSString
        let pages = pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        return max(pages.max() ?? 1, 1)
    }

    /// `GetPublishedFileDetails` response: the items that resolved (`result` 1).
    package static func details(_ data: Data) -> [WorkshopItem] {
        detailsResponse(data)?.items ?? []
    }

    /// `GetPublishedFileDetails` response: the items that resolved, and the ids that didn't (deleted, hidden or private).
    package static func detailsResponse(_ data: Data) -> (items: [WorkshopItem], missing: [String])? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = (o["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]] else { return nil }
        var items: [WorkshopItem] = [], missing: [String] = []
        for d in list {
            if (int(d["result"]) ?? 1) == 1, let i = item(d) {
                items.append(i)
            } else if let id = (d["publishedfileid"] as? String) ?? int(d["publishedfileid"]).map(String.init) {
                missing.append(id)
            }
        }
        return (items, missing)
    }

    /// One result object (both sources use the same field names).
    package static func item(_ o: [String: Any]) -> WorkshopItem? {
        guard let id = (o["publishedfileid"] as? String) ?? int(o["publishedfileid"]).map(String.init), !id.isEmpty,
              let title = o["title"] as? String else { return nil }
        let tags = ((o["tags"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
        let preview = (o["preview_url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return WorkshopItem(id: id, title: title, previewURL: preview, tags: tags,
                            fileSize: int64(o["file_size"]) ?? 0, subscriptions: int(o["subscriptions"]) ?? 0,
                            timeUpdated: int(o["time_updated"]) ?? 0, timeCreated: int(o["time_created"]) ?? 0,
                            description: (o["short_description"] as? String) ?? (o["description"] as? String) ?? "",
                            appID: int(o["consumer_app_id"]) ?? int(o["consumer_appid"]))
    }

    private static func ssrJSON(_ html: String) -> [String: Any]? {
        guard let idRange = html.range(of: "id=\"valve-ssr-data\""),
              let open = html[idRange.upperBound...].range(of: ">"),
              let close = html[open.upperBound...].range(of: "</script>") else { return nil }
        let text = String(html[open.upperBound..<close.lowerBound])
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }
}

/// Fetches browse pages and item details over HTTPS. No API key, no cookies, no account.
package final class WorkshopClient {
    package typealias Fetch = (URLRequest, @escaping (Data?, Error?) -> Void) -> Void
    private let fetch: Fetch

    /// `fetch` is replaceable for tests; the default is a cookie-less URLSession.
    package init(fetch: Fetch? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: config)
            self.fetch = { request, done in
                session.dataTask(with: request) { data, response, error in
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        done(nil, WorkshopError.http(http.statusCode))
                    } else {
                        done(data, error)
                    }
                }.resume()
            }
        }
    }

    /// A browse page; results arrive on the main queue.
    package func browse(_ query: WorkshopQuery, completion: @escaping (Result<WorkshopPage, Error>) -> Void) {
        var request = URLRequest(url: query.url)
        request.setValue("Mozilla/5.0 (photon2)", forHTTPHeaderField: "User-Agent")
        fetch(request) { [weak self] data, error in
            guard let data, let html = String(data: data, encoding: .utf8) else {
                return DispatchQueue.main.async { completion(.failure(error ?? WorkshopError.badResponse)) }
            }
            if let page = WorkshopParser.browsePage(html) {
                return DispatchQueue.main.async { completion(.success(page)) }
            }
            // Older layout: ids from the links, details from the API.
            let ids = WorkshopParser.ids(inBrowsePage: html)
            if ids.isEmpty {
                let empty = WorkshopPage(items: [], page: query.page, totalPages: query.page, totalCount: 0)
                return DispatchQueue.main.async { completion(.success(empty)) }
            }
            guard let self else { return }
            let pages = WorkshopParser.legacyPageCount(html)
            self.details(ids) { result in
                completion(result.map { items in
                    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    return WorkshopPage(items: ids.compactMap { byID[$0] }, page: query.page, totalPages: max(pages, query.page),
                                        totalCount: ids.count)
                })
            }
        }
    }

    /// `ISteamRemoteStorage/GetPublishedFileDetails/v1` (POST, no key) for up to 100 ids; results on the main queue.
    package func details(_ ids: [String], completion: @escaping (Result<[WorkshopItem], Error>) -> Void) {
        detailsWithMissing(ids) { completion($0.map(\.items)) }
    }

    /// `details`, plus the ids Steam didn't resolve.
    package func detailsWithMissing(_ ids: [String],
                                    completion: @escaping (Result<(items: [WorkshopItem], missing: [String]), Error>) -> Void) {
        guard !ids.isEmpty else { return DispatchQueue.main.async { completion(.success(([], []))) } }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let list = Array(ids.prefix(100))
        let body = (["itemcount=\(list.count)"] + list.enumerated().map { "publishedfileids%5B\($0.offset)%5D=\($0.element)" })
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        fetch(request) { data, error in
            let result: Result<(items: [WorkshopItem], missing: [String]), Error> =
                data.flatMap(WorkshopParser.detailsResponse).map { .success($0) } ?? .failure(error ?? WorkshopError.badResponse)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

package enum WorkshopError: LocalizedError {
    case http(Int)
    case badResponse

    package var errorDescription: String? {
        switch self {
        case .http(let code): return "Steam answered HTTP \(code)"
        case .badResponse: return "Steam's answer couldn't be read"
        }
    }
}

/// Workshop preview images kept on disk (`~/Library/Caches/photon2/workshop` / `~/.cache/photon2/workshop`), so
/// paging back and forth and reopening the browser don't download them again.
package final class WorkshopPreviewCache {
    package static let shared = WorkshopPreviewCache()
    package let directory: URL
    private let session: URLSession
    private var waiting: [String: [(URL?) -> Void]] = [:]
    private let lock = NSLock()

    package init(directory: URL? = nil) {
        #if os(macOS)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let caches = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        #endif
        self.directory = directory ?? caches.appendingPathComponent("photon2/workshop")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    package func file(for item: WorkshopItem, size: Int = 320) -> URL {
        directory.appendingPathComponent("\(item.id)-\(size)-\(item.timeUpdated)")
    }

    /// The local file for an item's preview (downloaded first when needed); called back on the main queue.
    package func preview(_ item: WorkshopItem, size: Int = 320, completion: @escaping (URL?) -> Void) {
        let file = file(for: item, size: size)
        if FileManager.default.fileExists(atPath: file.path) { return completion(file) }
        guard let url = item.thumbnailURL(size: size) else { return completion(nil) }
        lock.lock()
        if waiting[file.path] != nil {
            waiting[file.path]!.append(completion)
            lock.unlock()
            return
        }
        waiting[file.path] = [completion]
        lock.unlock()
        session.downloadTask(with: url) { [weak self] tmp, response, _ in
            guard let self else { return }
            var result: URL?
            if let tmp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                try? FileManager.default.removeItem(at: file)
                if (try? FileManager.default.moveItem(at: tmp, to: file)) != nil { result = file }
            }
            self.lock.lock()
            let callbacks = self.waiting.removeValue(forKey: file.path) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(result) } }
        }.resume()
    }
}
