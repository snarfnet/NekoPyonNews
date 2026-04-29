import SwiftUI
import Translation

@MainActor
class NewsViewModel: ObservableObject {
    @Published var sections: [NewsSection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var needsTranslation = false

    private var allItems: [NewsItem] = []

    private let excludeKeywords = [
        "caterpillar", "category", "categories", "catastrophe", "cataract",
        "catalyst", "catfish", "bobcat", "wildcat", "catamaran",
        "scatter", "concatenate", "cat scan", "catscan", "tomcat software"
    ]

    private let feeds: [(url: String, isEnglish: Bool, source: String)] = [
        (
            "https://news.google.com/rss/search?q=%E7%8C%AB+%E3%81%AD%E3%81%93+%E5%8B%95%E7%89%A9&hl=ja&gl=JP&ceid=JP:ja",
            false, "Google News"
        ),
        (
            "https://news.google.com/rss/search?q=cat+pets+kitten+-category+-catastrophe+-caterpillar+-catfish&hl=en&gl=US&ceid=US:en",
            true, "Google News"
        ),
        (
            "https://www.reddit.com/r/cats/.rss",
            true, "Reddit r/cats"
        ),
        (
            "https://www.reddit.com/r/catpictures/.rss",
            true, "Reddit r/catpictures"
        ),
        (
            "https://www.reddit.com/r/MEOW_IRL/.rss",
            true, "Reddit r/MEOW_IRL"
        ),
    ]

    func fetch() async {
        isLoading = true
        errorMessage = nil

        var combined: [NewsItem] = []
        await withTaskGroup(of: [NewsItem].self) { group in
            for feed in feeds {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.fetchRSS(urlString: feed.url, isEnglish: feed.isEnglish, source: feed.source)
                }
            }
            for await items in group {
                combined.append(contentsOf: items)
            }
        }

        combined.sort { $0.publishedDate > $1.publishedDate }
        var seen = Set<String>()
        combined = combined.filter { seen.insert($0.id).inserted }

        allItems = Array(combined.prefix(150))
        updateSections()
        isLoading = false

        if allItems.contains(where: { $0.isEnglish }) {
            needsTranslation = true
        }
    }

    func translateItems(using session: TranslationSession) async {
        let toTranslate = allItems.filter { $0.isEnglish && $0.translatedTitle == nil }
        guard !toTranslate.isEmpty else { return }

        let requests = toTranslate.map {
            TranslationSession.Request(sourceText: $0.title, clientIdentifier: $0.id)
        }
        do {
            for response in try await session.translations(from: requests) {
                if let idx = allItems.firstIndex(where: { $0.id == response.clientIdentifier }) {
                    allItems[idx].translatedTitle = response.targetText
                }
            }
            updateSections()
        } catch {
            print("Translation error: \(error)")
        }
    }

    private func updateSections() {
        let grouped = Dictionary(grouping: allItems) { $0.dateLabel }
        sections = grouped.keys.sorted { a, b in
            let dateA = grouped[a]!.first!.publishedDate
            let dateB = grouped[b]!.first!.publishedDate
            return dateA > dateB
        }.map { date in
            NewsSection(date: date, items: grouped[date]!.sorted { $0.publishedDate > $1.publishedDate })
        }
    }

    private func fetchRSS(urlString: String, isEnglish: Bool, source: String) async -> [NewsItem] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let parser = RSSParser(isEnglish: isEnglish, excludeKeywords: excludeKeywords, defaultSource: source)
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            return parser.items
        } catch {
            return []
        }
    }
}
