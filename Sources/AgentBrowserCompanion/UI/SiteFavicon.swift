import AppKit
import SwiftUI

struct SiteFavicon: View {
    let pageURL: URL?
    var fallbackColor: Color = .secondary
    @StateObject private var loader = FaviconLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(fallbackColor)
            }
        }
        .frame(width: 16, height: 16)
        .task(id: faviconURL) {
            await loader.load(from: faviconURL)
        }
    }

    private var faviconURL: URL? {
        guard let pageURL,
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

@MainActor
private final class FaviconLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()
    private var loadedURL: URL?

    func load(from url: URL?) async {
        guard loadedURL != url else { return }
        loadedURL = url
        image = nil
        guard let url else { return }

        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard loadedURL == url,
                  data.count <= 1_048_576,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.mimeType?.hasPrefix("image/") == true,
                  let decoded = NSImage(data: data) else { return }
            Self.cache.setObject(decoded, forKey: url as NSURL)
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}
