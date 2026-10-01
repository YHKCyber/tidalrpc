import Foundation

actor Metadata {
    private var cache: [String: SongInfo] = [:]
    private var order: [String] = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()
    private struct Artist: Decodable { let name: String }
    private struct Album: Decodable { let id: Int; let title: String?; let cover: String? }
    private struct Item: Decodable {
        let title: String; let artists: [Artist]; let duration: Double; let album: Album; let url: String?
    }
    private struct Search: Decodable { let items: [Item] }
    private struct AlbumDetails: Decodable { let title: String?; let releaseDate: String? }
    private func fetch<T: Decodable>(_ path: String, query: String? = nil) async throws -> T {
        var components = URLComponents(string: "https://api.tidal.com/v1/" + path)!
        components.queryItems = [URLQueryItem(name: "countryCode", value: "US")]
        if let query { components.queryItems! += [URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: "25")] }
        var request = URLRequest(url: components.url!)
        // Same public web-client token used by the original project, not a user credential.
        request.setValue("49YxDN9a2aFV6RTG", forHTTPHeaderField: "X-Tidal-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func fallback(_ key: String) -> SongInfo {
        let pieces = key.components(separatedBy: " - ")
        return SongInfo(title: pieces.dropLast().joined(separator: " - "), artist: pieces.last ?? "Unknown artist")
    }
    func lookup(_ key: String) async throws -> SongInfo {
        if let hit = cache[key] { return hit }
        let fallback = Self.fallback(key)
        let search: Search = try await fetch("search/tracks", query: String((fallback.title + " " + fallback.artist).prefix(160)))
        try Task.checkCancellation()
        // Match the full title/artist string, preserving delimiters within song titles.
        guard let hit = search.items.first(where: {
            ($0.title + " - " + $0.artists.map(\.name).joined(separator: ", ")).localizedCaseInsensitiveCompare(key) == .orderedSame
        }) else { throw URLError(.cannotParseResponse) }
        let details: AlbumDetails? = try? await fetch("albums/\(hit.album.id)")
        try Task.checkCancellation()
        let art = hit.album.cover.map { "https://resources.tidal.com/images/" + $0.replacingOccurrences(of: "-", with: "/") + "/1280x1280.jpg" }
        let song = SongInfo(title: hit.title, artist: hit.artists.map(\.name).joined(separator: ", "),
                            album: details?.title ?? hit.album.title, year: details?.releaseDate.map { String($0.prefix(4)) },
                            duration: hit.duration, artwork: art, url: hit.url)
        cache[key] = song; order.removeAll { $0 == key }; order.append(key)
        while order.count > 32 { cache.removeValue(forKey: order.removeFirst()) }
        return song
    }
}
