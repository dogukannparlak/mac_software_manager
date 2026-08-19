import Foundation

/// Groups the CLI Tools page.
///
/// Homebrew has no first-class "category" for a formula, so this leans on the
/// one piece of real metadata it does expose - `brew leaves` (what the user
/// actually asked for) versus everything pulled in transitively - plus a
/// keyword heuristic over each leaf's own `brew desc` description. A formula
/// that is not a leaf is someone else's dependency, not a tool the user
/// thinks of as "a CLI tool with a category", so it always lands in
/// `.libraries` regardless of what it does - see `LibrarySubcategory` for how
/// that bucket is broken down further.
enum CLIToolCategory: String, CaseIterable, Identifiable, Sendable {
    case versionControl
    case languagesRuntimes
    case cloudDevOpsAI
    case databases
    case networkingSecurity
    case buildPackaging
    case mediaDocuments
    case shellText
    case testing
    case other
    case libraries

    var id: String { rawValue }

    /// Display order - leaf categories first (most to least common), the
    /// catch-all leaf bucket next, dependencies last.
    var sortRank: Int {
        switch self {
        case .versionControl: return 0
        case .languagesRuntimes: return 1
        case .cloudDevOpsAI: return 2
        case .databases: return 3
        case .networkingSecurity: return 4
        case .buildPackaging: return 5
        case .mediaDocuments: return 6
        case .shellText: return 7
        case .testing: return 8
        case .other: return 9
        case .libraries: return 10
        }
    }

    var symbol: String {
        switch self {
        case .versionControl: return "arrow.triangle.branch"
        case .languagesRuntimes: return "chevron.left.forwardslash.chevron.right"
        case .cloudDevOpsAI: return "cloud"
        case .databases: return "cylinder"
        case .networkingSecurity: return "lock.shield"
        case .buildPackaging: return "hammer"
        case .mediaDocuments: return "photo"
        case .shellText: return "text.alignleft"
        case .testing: return "checkmark.seal"
        case .other: return "wrench.and.screwdriver"
        case .libraries: return "books.vertical"
        }
    }

    var label: Localized {
        switch self {
        case .versionControl:
            return Localized("Version Control", "Sürüm Kontrolü")
        case .languagesRuntimes:
            return Localized("Languages & Runtimes", "Diller ve Çalışma Zamanları")
        case .cloudDevOpsAI:
            return Localized("Cloud, DevOps & AI", "Bulut, DevOps ve Yapay Zeka")
        case .databases:
            return Localized("Databases", "Veritabanları")
        case .networkingSecurity:
            return Localized("Networking & Security", "Ağ ve Güvenlik")
        case .buildPackaging:
            return Localized("Build & Package Tools", "Derleme ve Paket Araçları")
        case .mediaDocuments:
            return Localized("Media & Documents", "Medya ve Belgeler")
        case .shellText:
            return Localized("Shell & Text Utilities", "Kabuk ve Metin Araçları")
        case .testing:
            return Localized("Testing", "Test Araçları")
        case .other:
            return Localized("Other Tools", "Diğer Araçlar")
        case .libraries:
            return Localized("Libraries & Dependencies", "Kütüphaneler ve Bağımlılıklar")
        }
    }
}

/// A finer breakdown shown only inside `.libraries` - the transitive
/// dependency pile is the biggest bucket on most machines (build toolchains
/// pull in dozens of small C libraries), so it gets its own sub-headings
/// instead of one long flat list.
enum LibrarySubcategory: String, CaseIterable, Identifiable, Sendable {
    case awsSDK
    case compression
    case networkingSecurity
    case graphicsMedia
    case textData
    case databases
    case languageRuntimeSupport
    case windowing
    case core

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .languageRuntimeSupport: return 0
        case .networkingSecurity: return 1
        case .databases: return 2
        case .graphicsMedia: return 3
        case .textData: return 4
        case .compression: return 5
        case .awsSDK: return 6
        case .windowing: return 7
        case .core: return 8
        }
    }

    var label: Localized {
        switch self {
        case .awsSDK:
            return Localized("AWS SDK Components", "AWS SDK Bileşenleri")
        case .compression:
            return Localized("Compression & Archiving", "Sıkıştırma ve Arşivleme")
        case .networkingSecurity:
            return Localized("Networking & Security Libraries", "Ağ ve Güvenlik Kütüphaneleri")
        case .graphicsMedia:
            return Localized("Graphics, Fonts & Media Libraries", "Grafik, Yazı Tipi ve Medya Kütüphaneleri")
        case .textData:
            return Localized("Text, Unicode & Data Libraries", "Metin, Unicode ve Veri Kütüphaneleri")
        case .databases:
            return Localized("Databases", "Veritabanları")
        case .languageRuntimeSupport:
            return Localized("Language Runtime Support", "Dil Çalışma Zamanı Desteği")
        case .windowing:
            return Localized("X11 / Windowing", "X11 / Pencereleme")
        case .core:
            return Localized("Core & System Libraries", "Çekirdek ve Sistem Kütüphaneleri")
        }
    }
}

/// The keyword heuristics behind `CLIToolCategory` and `LibrarySubcategory`.
/// Kept separate from the enums so the matching tables and their ordering
/// (first match wins) are easy to scan and to test in isolation.
enum CLIToolCategorizer {

    /// One rule: if any keyword appears in the lowercased "token
    /// description" text, this formula belongs to `category`. Ordered by
    /// priority - the first rule that matches wins, so put more specific
    /// phrases before broader ones.
    private struct Rule<Category> {
        let category: Category
        let keywords: [String]
    }

    /// Deliberately broader than just what happens to be installed right
    /// now - covers common phrasing across the wider Homebrew ecosystem
    /// (container tooling, popular languages, common dev-adjacent
    /// categories) so a typical user's leaves mostly land in a real
    /// category instead of piling up in `.other`.
    private static let rules: [Rule<CLIToolCategory>] = [
        Rule(category: .versionControl, keywords: [
            "revision control", "version control", "source control",
            "git extension", "git client", "github command", "gitlab",
            "distributed scm", "mercurial", "subversion", "code review",
            "diff and merge tool", "commit",
        ]),
        Rule(category: .languagesRuntimes, keywords: [
            "programming language", "scripting language", "runtime for",
            "runtime environment", "interpreter for", "language runtime",
            "compiler for the", "development kit for the java", "typescript",
            "static type checker", "bytecode", "virtual machine for",
            "javascript engine",
        ]),
        Rule(category: .cloudDevOpsAI, keywords: [
            "amazon aws", " aws ", "google cloud", "microsoft azure",
            "kubernetes", "docker", "container runtime", "container registry",
            "container orchestration", "terraform", "ansible", "pulumi",
            "infrastructure as code", "provisioning tool", "service mesh",
            "continuous integration", "continuous deployment", "ci/cd",
            "serverless", "ai model", "machine learning", "artificial intelligence",
            "large language model", "language model", " llm ", "chatbot",
            "generative ai", "openai", "anthropic",
        ]),
        Rule(category: .databases, keywords: [
            "relational database", "database management", "database engine",
            "key-value store", "in-memory data structure store", " sql ",
            "sql database", "postgresql", "mysql", "sqlite", "mongodb",
            "time series database", "graph database", "search engine for",
            "message broker", "cache server",
        ]),
        Rule(category: .networkingSecurity, keywords: [
            "network protocol", "network library", "network tool",
            "http client", "http/2", "http server", "encryption", "cryptograph",
            " tls ", " ssl ", "certificate", "ssh client", "firewall",
            "proxy server", "reverse proxy", "load balancer", " dns ", " vpn ",
            "gnupg", "openpgp", "packet capture", "packet analyzer",
            "vulnerability scanner", "penetration testing", "secret management",
            "password manager", "two-factor", "port scanner",
        ]),
        Rule(category: .buildPackaging, keywords: [
            "build system", "build tool", "build automation",
            "package manager", "dependency manager", "compiler collection",
            "task runner", "module bundler", "code formatter", "static analysis",
            "linter", "makefile", "linker",
        ]),
        Rule(category: .mediaDocuments, keywords: [
            "image processing", "image manipulation", "video downloader",
            "audio/video", "graphics library", "font rendering", " pdf ",
            "optical character recognition", " ocr ", "photo", "screenshot",
            "screen recorder", "document converter", "ebook", "subtitle",
            "media player", "transcoding",
        ]),
        Rule(category: .shellText, keywords: [
            "shell", "terminal emulator", "text editor", "command-line tool",
            "text processing", "regular expression", "fuzzy finder",
            "pretty-print", "syntax highlight", "file manager",
            "directory listing", "process viewer", "system monitor",
            "clipboard manager", "note-taking", "markdown", "spell check",
        ]),
        Rule(category: .testing, keywords: [
            "test framework", "testing system", "testing framework",
            "unit test", " testing ", "mocking framework", "code coverage",
            "browser automation", "end-to-end testing", "load testing",
            "fuzz testing",
        ]),
    ]

    /// A separate, smaller vocabulary tuned for how Homebrew phrases C/C++
    /// library descriptions (very different register from end-user tool
    /// descriptions), applied only within `.libraries`.
    private static let librarySubcategoryRules: [Rule<LibrarySubcategory>] = [
        Rule(category: .awsSDK, keywords: [" aws", "aws-", "amazon"]),
        Rule(category: .languageRuntimeSupport, keywords: [
            "programming language", "scripting language", "runtime for",
            "runtime environment", "javascript", "syscall api", "wasi",
        ]),
        Rule(category: .graphicsMedia, keywords: [
            "graphics", "image", "font", "pixel", " gif", "codec",
            "color management", "text shaping", "layout and rendering",
            "vector graphics", " ocr", "tiff", "video", "audio",
        ]),
        Rule(category: .compression, keywords: [
            "compression", "archiving", "archive format", "huffman",
            "checksum", "crc32", "lossless",
        ]),
        Rule(category: .networkingSecurity, keywords: [
            "http/2", "http/3", "quic", "dns", " tls", " ssl", "url parser",
            "certificate", "cryptography", "http_parser", " http ",
        ]),
        Rule(category: .textData, keywords: [
            "unicode", "json", "yaml", "internationalization", "localization",
            "trie", "thai", "byte handling", "regular expression",
        ]),
        Rule(category: .databases, keywords: ["database", "sqlite", " sql "]),
        Rule(category: .windowing, keywords: ["x.org", "x11", "xorg"]),
    ]

    /// Parses `brew desc`'s own output format, one formula per line:
    /// `token: one-line description`. Lines that don't match are skipped
    /// rather than guessed at.
    static func parseDescriptions(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let token = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let description = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[token] = description
        }
        return result
    }

    private static func haystack(token: String, description: String?) -> String {
        " \(token) \((description ?? "")) ".lowercased()
    }

    /// `isLeaf` is Homebrew's own signal for "the user asked for this
    /// directly" (`brew leaves`) versus "this got pulled in as someone
    /// else's dependency". Only leaves go through the keyword heuristic -
    /// everything else is `.libraries`, regardless of what it does.
    static func categorize(token: String, description: String?, isLeaf: Bool) -> CLIToolCategory {
        guard isLeaf else { return .libraries }

        let text = haystack(token: token, description: description)
        for rule in rules where rule.keywords.contains(where: { text.contains($0) }) {
            return rule.category
        }
        return .other
    }

    /// Only meaningful for a formula already categorized as `.libraries`;
    /// callers should not call this for a leaf.
    static func librarySubcategory(token: String, description: String?) -> LibrarySubcategory {
        let text = haystack(token: token, description: description)
        for rule in librarySubcategoryRules where rule.keywords.contains(where: { text.contains($0) }) {
            return rule.category
        }
        return .core
    }
}
