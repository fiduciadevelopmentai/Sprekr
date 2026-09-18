import Foundation

/// Canonical spellings for brands, devices, developer tools and AI models that
/// Parakeet routinely renders phonetically, especially when an English term is
/// spoken inside Dutch dictation ("macboek", "gitte hub", "tsjat gpt").
///
/// This stays deterministic and fully local. The table is data-as-code for the
/// same reason as the other spoken-form tables: `SprekrApp` is an executable
/// target without a resource bundle, so a JSON file would not survive
/// `scripts/build-app.sh`.
///
/// Two matching modes keep ordinary prose intact:
///
/// - Unguarded variants are forms that are not words in Dutch or English, so a
///   match is unambiguous and is always corrected.
/// - Guarded variants are real words (`cursor`, `claude`, `react`) and are only
///   corrected next to an explicit context cue, mirroring the existing
///   `spreker` -> `Sprekr` rule in `SelfCorrectionFormatter`.
///
/// The user's editable Dictionary still runs after this pass and always wins.
enum TermLexicon {
    struct Entry {
        let canonical: String
        let variants: [String]
        let category: Category
        let contextCues: [String]
        /// Variants that are real words in Dutch or English (`appel`,
        /// `amazone`), so they need the same context cue as the canonical
        /// form. Every other variant of a guarded entry is a phonetic
        /// non-word and is corrected unconditionally.
        let guardedVariants: [String]

        /// Marks a canonical form whose lowercase opening is deliberate
        /// (`iPhone`, `npm`, `macOS`), so neither this pass nor the
        /// sentence-case pass may change it.
        let isCaseLocked: Bool

        var isGuarded: Bool { !contextCues.isEmpty }

        /// True when this particular spelling needs a context cue before it
        /// may be rewritten.
        func requiresCue(for matched: String) -> Bool {
            guard isGuarded else { return false }
            let key = TermLexicon.normalizedKey(matched)
            return key == TermLexicon.normalizedKey(canonical)
                || guardedVariants.contains { TermLexicon.normalizedKey($0) == key }
        }

        /// A canonical form carrying any capital is a brand spelling and is
        /// emitted verbatim. A fully lowercase one is an ordinary word, so the
        /// dictated capitalization is preserved instead.
        var usesVerbatimCasing: Bool {
            isCaseLocked || canonical.contains(where: \.isUppercase)
        }

        init(
            _ canonical: String,
            _ variants: [String],
            category: Category,
            cues: [String] = [],
            guardedVariants: [String] = [],
            caseLocked: Bool = false
        ) {
            self.canonical = canonical
            self.variants = variants + guardedVariants
            self.category = category
            self.contextCues = cues
            self.guardedVariants = guardedVariants
            self.isCaseLocked = caseLocked
        }
    }

    enum Category: String, CaseIterable {
        case hardware = "Hardware"
        case platform = "Platforms"
        case tooling = "Developer tools"
        case language = "Languages & frameworks"
        case service = "Services"
        case artificialIntelligence = "AI models"
        case codeSwitch = "Dutch/English spelling"
    }

    // MARK: - Public surface

    /// Replaces every confident variant with its canonical spelling.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty, let expression = combinedExpression else { return text }

        let source = text as NSString
        let emailRanges = SpokenEmailFormatter.validEmailRanges(in: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )

        var result = text
        for match in matches.reversed() {
            let matched = source.substring(with: match.range)
            guard let entry = variantIndex[normalizedKey(matched)] else { continue }
            guard !isProtected(match.range, in: text, emailRanges: emailRanges) else { continue }
            if entry.requiresCue(for: matched), !hasContextCue(for: entry, around: match.range, in: source) {
                continue
            }
            let replacement = entry.usesVerbatimCasing
                ? entry.canonical
                : preservingWordCase(of: matched, in: entry.canonical)
            guard replacement != matched, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// True when the word carries deliberate lowercase casing, so the
    /// sentence-case pass must leave it alone.
    static func isCaseLocked(_ word: String) -> Bool {
        guard let entry = canonicalIndex[normalizedKey(word)] else { return false }
        return entry.isCaseLocked
    }

    /// True when the word is a known canonical term or a known variant, so the
    /// spell-checked repair pass must not second-guess it.
    static func isKnownTerm(_ word: String) -> Bool {
        variantIndex[normalizedKey(word)] != nil
    }

    static var entriesByCategory: [(category: Category, entries: [Entry])] {
        Category.allCases.compactMap { category in
            let matching = entries
                .filter { $0.category == category }
                .sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    static var termCount: Int { entries.count }

    // MARK: - Matching

    /// Keeps the pass away from addresses, URLs and file paths, where a term
    /// such as `github` is part of an identifier rather than prose.
    private static func isProtected(
        _ range: NSRange,
        in text: String,
        emailRanges: [NSRange]
    ) -> Bool {
        let insideEmail = emailRanges.contains { emailRange in
            range.location >= emailRange.location && NSMaxRange(range) <= NSMaxRange(emailRange)
        }
        if insideEmail { return true }

        let source = text as NSString
        var start = range.location
        while start > 0, !isTokenSeparator(source.character(at: start - 1)) {
            start -= 1
        }
        var end = NSMaxRange(range)
        while end < source.length, !isTokenSeparator(source.character(at: end)) {
            end += 1
        }
        let token = source.substring(with: NSRange(location: start, length: end - start))
        if token.contains("/") || token.contains("\\") || token.contains("@") { return true }
        // "github.com", "next.config.js": a term that is only part of a dotted
        // identifier keeps that identifier's casing. A term that is the whole
        // token ("node.js") is still normalized.
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”'‘’()[]"))
        guard (trimmed as NSString).length > range.length else { return false }
        return trimmed.range(
            of: #"[\p{L}\p{N}]\.[\p{L}\p{N}]"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTokenSeparator(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func hasContextCue(
        for entry: Entry,
        around range: NSRange,
        in source: NSString
    ) -> Bool {
        let leadingStart = max(0, range.location - contextWindow)
        let leading = source.substring(
            with: NSRange(location: leadingStart, length: range.location - leadingStart)
        )
        let trailingStart = NSMaxRange(range)
        let trailingLength = min(contextWindow, source.length - trailingStart)
        let trailing = source.substring(
            with: NSRange(location: trailingStart, length: trailingLength)
        )
        let window = leading + " " + trailing

        return entry.contextCues.contains { cue in
            let escaped = NSRegularExpression.escapedPattern(for: cue)
            return window.range(
                of: #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static let contextWindow = 48

    private static func preservingWordCase(of source: String, in replacement: String) -> String {
        if source == source.uppercased(), source.contains(where: \.isLetter) {
            return replacement.uppercased()
        }
        guard source.first?.isUppercase == true, let first = replacement.first else {
            return replacement
        }
        return String(first).uppercased() + replacement.dropFirst()
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - Compiled tables

    private static let variantIndex: [String: Entry] = {
        var index: [String: Entry] = [:]
        for entry in entries {
            for variant in entry.variants + [entry.canonical] {
                index[normalizedKey(variant)] = entry
            }
        }
        return index
    }()

    private static let canonicalIndex: [String: Entry] = {
        var index: [String: Entry] = [:]
        for entry in entries {
            index[normalizedKey(entry.canonical)] = entry
        }
        return index
    }()

    /// One alternation, longest variant first so the leftmost-first alternation
    /// prefers `chat gpt` over a bare `gpt`.
    private static let combinedExpression: NSRegularExpression? = {
        var seen: Set<String> = []
        var alternatives: [String] = []
        for entry in entries {
            for variant in entry.variants + [entry.canonical] {
                let key = normalizedKey(variant)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                alternatives.append(key)
            }
        }
        alternatives.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }
        let patterns = alternatives.map { variant in
            variant
                .split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[ \t]+"#)
        }
        guard !patterns.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + patterns.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
}

// MARK: - The table

extension TermLexicon {
    fileprivate static let entries: [Entry] = [
        // Apple hardware
        Entry("MacBook", ["macboek", "mac boek", "mac book", "mekboek", "mekbook"], category: .hardware),
        Entry("MacBook Air", ["macboek air", "mac boek air"], category: .hardware),
        Entry("MacBook Pro", ["macboek pro", "mac boek pro"], category: .hardware),
        Entry("iPhone", ["ai phone", "ei phone", "iefoon", "ai foon", "eye phone"], category: .hardware, caseLocked: true),
        Entry("iPad", ["ai pad", "ei pad", "eye pad"], category: .hardware, caseLocked: true),
        Entry("iMac", ["ai mac", "i mac", "ei mac"], category: .hardware, caseLocked: true),
        Entry("AirPods", ["air pods", "airpod", "er pods", "air pot"], category: .hardware),
        Entry("Apple Watch", ["apple wats", "appel watch", "apple wodge"], category: .hardware),
        Entry("Mac mini", ["mac minie", "mec mini"], category: .hardware),
        Entry("Mac Studio", ["mec studio"], category: .hardware),
        Entry("Apple Silicon", ["apple silicone", "appel silicon"], category: .hardware),
        Entry("Neural Engine", ["neurale engine", "neural enzjin"], category: .hardware),

        // Apple platforms
        Entry("macOS", ["mac os", "mac o s", "mek os"], category: .platform, caseLocked: true),
        Entry("iOS", ["i o s", "ai o s"], category: .platform, caseLocked: true),
        Entry("iPadOS", ["ipad os", "i pad os"], category: .platform, caseLocked: true),
        Entry("watchOS", ["watch os", "wodge os"], category: .platform, caseLocked: true),
        Entry("visionOS", ["vision os"], category: .platform, caseLocked: true),
        Entry("Xcode", ["ex code", "ex kode", "x code", "eks code"], category: .platform),
        Entry("TestFlight", ["test flight", "test flait"], category: .platform),
        Entry("App Store", ["appstore", "app stoor"], category: .platform),
        Entry("Keychain", ["key chain", "kie chain"], category: .platform),
        Entry("Spotlight", ["spot light", "spotlicht"], category: .platform),
        Entry("Finder", ["fainder"], category: .platform, cues: ["mac", "macos", "map", "folder", "venster", "window", "bestand", "file"]),
        Entry("Terminal", [], category: .platform, cues: ["command", "commando", "shell", "zsh", "bash", "venster"], guardedVariants: ["terminaal"]),

        // Developer tools
        Entry("GitHub", ["gitte hub", "git hub", "gethub", "gitub", "githup", "guithub"], category: .tooling),
        Entry("GitLab", ["git lab", "gitte lab", "getlab"], category: .tooling),
        Entry("Git", ["gitte"], category: .tooling, cues: ["commit", "branch", "repo", "repository", "push", "pull", "merge", "rebase", "clone", "checkout"]),
        Entry("VS Code", ["wie es code", "v s code", "vies studio code", "visual studio code", "vee es code"], category: .tooling),
        Entry("Cursor", ["curser", "kursor"], category: .tooling, cues: ["editor", "ide", "agent", "composer", "prompt", "chat", "codebase"]),
        Entry("Docker", ["dokker", "docher", "doker"], category: .tooling),
        Entry("Kubernetes", ["koebernetes", "kubernetis", "koebernetis"], category: .tooling),
        Entry("Homebrew", ["home brew", "homebrouw", "hoombrew"], category: .tooling),
        Entry("npm", ["en pee em", "n p m"], category: .tooling, caseLocked: true),
        Entry("pnpm", ["pee en pee em", "p n p m"], category: .tooling, caseLocked: true),
        Entry("Yarn", ["jarn"], category: .tooling, cues: ["install", "package", "npm", "pnpm", "build", "script"]),
        Entry("ESLint", ["es lint", "e s lint"], category: .tooling),
        Entry("Prettier", ["pretier"], category: .tooling, cues: ["format", "formatter", "eslint", "lint", "config"]),
        Entry("Vite", ["viet"], category: .tooling, cues: ["build", "dev", "server", "bundler", "config", "plugin"]),
        Entry("Webpack", ["web pack", "webpek"], category: .tooling),
        Entry("Turbopack", ["turbo pack", "turbopek"], category: .tooling),
        Entry("SwiftLint", ["swift lint"], category: .tooling),
        Entry("CocoaPods", ["cocoa pods", "koko pods"], category: .tooling),
        Entry("PowerShell", ["power shell", "pauwer shell", "powersjel"], category: .tooling),
        Entry("Playwright", ["play wright", "pleeraait", "playwrite"], category: .tooling),
        Entry("Terraform", ["terra form", "terraforum"], category: .tooling),
        Entry("Raycast", ["ray cast", "reecast"], category: .tooling),
        Entry("Obsidian", ["obsidiaan"], category: .tooling, cues: ["vault", "notitie", "notities", "note", "notes", "markdown", "plugin"]),
        Entry("Jira", ["djira", "jiera"], category: .tooling),
        Entry("Sentry", ["sentrie"], category: .tooling, cues: ["error", "errors", "fout", "fouten", "logging", "monitoring", "crash", "issue"]),
        Entry("Bun", ["bunn"], category: .tooling, cues: ["install", "runtime", "npm", "package", "script", "javascript", "typescript"]),
        Entry("Deno", ["dieno", "deeno"], category: .tooling),

        // Languages and frameworks
        Entry("JavaScript", ["java script", "sjavascript", "djava script", "javascrip"], category: .language),
        Entry("TypeScript", ["type script", "taipscript", "taip script"], category: .language),
        Entry("SwiftUI", ["swift ui", "swift u i", "swiftjoeai"], category: .language),
        Entry("AppKit", ["app kit", "appkid"], category: .language),
        Entry("UIKit", ["ui kit", "u i kit"], category: .language),
        Entry("Core ML", ["core m l", "coreml", "kor em el", "koor em el"], category: .language),
        Entry("Core Data", ["coredata", "kor data"], category: .language),
        Entry("Node.js", ["node js", "noded js", "node jee es", "nodejs"], category: .language),
        Entry("Next.js", ["next js", "nekst js", "nextjs", "next jee es"], category: .language),
        Entry("Nuxt", ["nukst", "nuxed"], category: .language, cues: ["vue", "framework", "app", "project", "component"]),
        Entry("React", ["riakt", "rieakt"], category: .language, cues: ["component", "hook", "hooks", "jsx", "state", "props", "native", "framework", "app"]),
        Entry("React Native", ["react netive", "riakt native"], category: .language),
        Entry("Vue", ["vjoe"], category: .language, cues: ["component", "framework", "nuxt", "app", "template"]),
        Entry("Svelte", ["sfelt", "svelt"], category: .language, cues: ["component", "framework", "app", "kit", "store"]),
        Entry("Angular", ["enguler"], category: .language, cues: ["component", "framework", "module", "service", "app"]),
        Entry("Tailwind", ["teilwind", "tailwint", "tail wind"], category: .language),
        Entry("Python", ["paiton", "paithon"], category: .language),
        Entry("Swift", ["swiftt"], category: .language, cues: ["package", "code", "xcode", "apple", "concurrency", "compiler", "actor", "protocol"]),
        Entry("Kotlin", ["cotlin", "kotlien"], category: .language),
        Entry("PostgreSQL", ["postgres q l", "postgre sql"], category: .language),
        Entry("Postgres", ["postgress", "post gres"], category: .language),
        Entry("SQLite", ["sequel lite", "es q l lite"], category: .language),
        Entry("GraphQL", ["graph q l", "grafql"], category: .language),
        Entry("JSON", ["djeeson", "jay son", "dzjeson"], category: .language),
        Entry("YAML", ["jamel", "ja mel"], category: .language),
        Entry("HTML", ["h t m l", "hatteemel"], category: .language),
        Entry("CSS", ["c s s", "see es es"], category: .language),
        Entry("SQL", ["s q l"], category: .language),
        Entry("API", ["a p i", "ee pee ie", "ay pee eye"], category: .language),
        Entry("CLI", ["c l i", "see el ie"], category: .language),
        Entry("SDK", ["s d k", "es dee ka"], category: .language),
        Entry("HTTP", ["h t t p"], category: .language),
        Entry("HTTPS", ["h t t p s"], category: .language),
        Entry("URL", ["u r l", "joe er el"], category: .language),
        Entry("UI", ["u i"], category: .language, cues: ["design", "component", "ontwerp", "interface", "swift", "kit", "library"]),
        Entry("UX", ["u x", "joe eks"], category: .language, cues: ["design", "ontwerp", "research", "writer", "interface", "user"]),
        Entry("Prisma", ["prizma", "prisma orm"], category: .language),
        Entry("Redis", ["reddis", "riedis"], category: .language),
        Entry("MongoDB", ["mongo db", "mongo dee bee", "mongodb"], category: .language),
        Entry("MySQL", ["my sql", "mai sequel", "my sequel", "mysql"], category: .language),
        Entry("FastAPI", ["fast api", "fast a p i", "fastapi"], category: .language),
        Entry("Rust", ["rustt"], category: .language, cues: ["cargo", "crate", "compiler", "borrow", "language", "taal"]),

        // Services
        Entry("Vercel", ["versel", "vercell", "wercel"], category: .service),
        Entry("Supabase", ["soepabase", "soepa base", "super base", "supa base"], category: .service),
        Entry("Firebase", ["fire base", "fairbase", "vuurbase"], category: .service),
        Entry("Netlify", ["net lify", "netlifie"], category: .service),
        Entry("Cloudflare", ["cloud flare", "cloudflair", "klaudflare"], category: .service),
        Entry("Figma", ["figmah", "fickma"], category: .service),
        Entry("Stripe", ["straip"], category: .service, cues: ["betaling", "payment", "checkout", "subscription", "abonnement", "webhook", "api", "invoice", "factuur"]),
        Entry("Notion", ["nosjon", "noshun"], category: .service, cues: ["pagina", "page", "database", "workspace", "doc", "notitie"]),
        Entry("Slack", ["slek"], category: .service, cues: ["channel", "kanaal", "bericht", "message", "workspace", "thread", "bot"]),
        Entry("Linear", ["linair"], category: .service, cues: ["issue", "ticket", "sprint", "cycle", "backlog"]),
        Entry("LinkedIn", ["linked in", "linkt in"], category: .service),
        Entry("YouTube", ["you tube", "joetjoep"], category: .service),
        Entry("WhatsApp", ["whats app", "wats app"], category: .service),
        Entry("Instagram", ["insta gram"], category: .service),
        Entry("TikTok", ["tik tok"], category: .service),
        Entry("Spotify", ["spotifai"], category: .service),
        Entry("Google", ["gogle", "goegle"], category: .service),
        Entry("Microsoft", ["micro soft", "maikrosoft"], category: .service),
        Entry("Apple", [], category: .service, cues: ["mac", "macbook", "iphone", "ipad", "silicon", "developer", "watch", "store", "music"], guardedVariants: ["appel"]),
        Entry("Amazon", [], category: .service, cues: ["web", "services", "aws", "bestelling", "order", "prime"], guardedVariants: ["amazone"]),
        Entry("AWS", ["a w s", "ee doebeljoe es"], category: .service),
        Entry("Azure", ["ezjur", "asuur"], category: .service, cues: ["microsoft", "cloud", "portal", "functions", "devops", "storage"]),
        Entry("Gmail", ["g mail", "gee mail", "gmeel"], category: .service),
        Entry("Outlook", ["out look", "outloek"], category: .service),
        Entry("iCloud", ["ai cloud", "i cloud", "ei cloud", "eye cloud"], category: .service, caseLocked: true),
        Entry("Safari", ["safarie"], category: .service, cues: ["browser", "tab", "tabblad", "apple", "mac", "iphone", "website", "webkit"]),
        Entry("Chrome", ["kroom", "google chroom"], category: .service, cues: ["browser", "tab", "tabblad", "google", "extensie", "extension", "website", "devtools"]),
        Entry("Bluetooth", ["blue tooth", "bloetoef", "bloetoet"], category: .hardware),
        Entry("USB-C", ["usb c", "u s b c", "joe es bee see"], category: .hardware),
        Entry("Dropbox", ["drop box", "dropboks"], category: .service),
        Entry("Google Drive", ["google draif", "google dryve"], category: .service),
        Entry("Shopify", ["shoppify", "sjopifai", "shopifai"], category: .service),
        Entry("WordPress", ["word press", "wordpres", "wortpress"], category: .service),
        Entry("Webflow", ["web flow", "webflo"], category: .service),
        Entry("Framer", ["freemer"], category: .service, cues: ["site", "website", "design", "ontwerp", "template", "landing", "pagina", "page"]),
        Entry("Canva", ["kanva", "canfa"], category: .service),
        Entry("Zapier", ["zappier", "zeepier"], category: .service),
        Entry("n8n", ["n acht n", "en acht en", "n eight n", "en eight en"], category: .service, caseLocked: true),
        Entry("Airtable", ["air table", "airtabel"], category: .service),
        Entry("HubSpot", ["hub spot", "hubspot", "hupspot"], category: .service),
        Entry("Discord", ["dis cord", "diskord"], category: .service),
        Entry("Teams", ["tiems"], category: .service, cues: ["microsoft", "meeting", "vergadering", "call", "chat", "kanaal", "channel"]),
        Entry("Zoom", [], category: .service, cues: ["meeting", "vergadering", "call", "webinar"], guardedVariants: ["zoem"]),

        // AI models and companies
        Entry("ChatGPT", ["chat gpt", "tsjat gpt", "sjet gpt", "chat g p t", "chat gee pee tee", "chat jipietie"], category: .artificialIntelligence),
        Entry("OpenAI", ["open ai", "open a i", "open ay i"], category: .artificialIntelligence),
        Entry("Anthropic", ["antropic", "antropik", "anthropik"], category: .artificialIntelligence),
        Entry("Claude", ["klode"], category: .artificialIntelligence, cues: ["anthropic", "model", "sonnet", "opus", "haiku", "prompt", "assistent", "assistant", "code"]),
        Entry("Sonnet", ["sonet"], category: .artificialIntelligence, cues: ["claude", "anthropic", "model", "opus", "haiku"]),
        Entry("Opus", ["oppus"], category: .artificialIntelligence, cues: ["claude", "anthropic", "model", "sonnet", "haiku"]),
        Entry("Gemini", ["gemenie", "djemini"], category: .artificialIntelligence, cues: ["google", "model", "pro", "flash", "prompt", "deepmind"]),
        Entry("Copilot", ["co pilot", "kopilot"], category: .artificialIntelligence),
        Entry("GPT", ["gee pee tee", "g p t", "jipietie"], category: .artificialIntelligence),
        Entry("LLM", ["l l m", "el el em"], category: .artificialIntelligence),
        Entry("NVIDIA", ["invidia", "en vidia"], category: .artificialIntelligence),
        Entry("Hugging Face", ["hugging fase", "hugingface"], category: .artificialIntelligence),
        Entry("Whisper", ["wisper"], category: .artificialIntelligence, cues: ["model", "openai", "transcriptie", "transcription", "asr", "audio", "speech"]),
        Entry("Parakeet", ["para keet"], category: .artificialIntelligence, cues: ["model", "nvidia", "tdt", "asr", "transcriptie", "transcription", "fluidaudio"], guardedVariants: ["parakiet"]),
        Entry("Claude Code", ["klode code", "claude kode", "cloud code"], category: .artificialIntelligence),
        Entry("Codex", ["kodex", "codeks"], category: .artificialIntelligence, cues: ["openai", "agent", "cli", "model", "prompt", "code"]),
        Entry("Mistral", ["mistraal", "mistrall"], category: .artificialIntelligence),
        Entry("Perplexity", ["perplexitie", "perpleksity", "perplexety"], category: .artificialIntelligence),
        Entry("Midjourney", ["mid journey", "midjourny", "midjurney"], category: .artificialIntelligence),
        Entry("DeepSeek", ["deep seek", "diepseek", "deepsiek"], category: .artificialIntelligence),
        Entry("Ollama", ["olama", "o lama"], category: .artificialIntelligence),
        Entry("Llama", [], category: .artificialIntelligence, cues: ["meta", "model", "ollama", "open source", "weights", "llm"], guardedVariants: ["lama"]),
        Entry("Grok", ["grock"], category: .artificialIntelligence, cues: ["xai", "x ai", "model", "elon", "twitter", "prompt"]),

        // Dutch/English code-switch spellings
        Entry("tweak", ["tweek"], category: .codeSwitch),
        Entry("tweaken", ["tweeken"], category: .codeSwitch),
        Entry("tweakt", ["tweekt"], category: .codeSwitch),
        Entry("getweakt", ["getweekt"], category: .codeSwitch),
        Entry("tweaking", ["tweeking"], category: .codeSwitch),
        Entry("tweaked", ["tweeked"], category: .codeSwitch),
        Entry("deployen", ["deploien", "diploien"], category: .codeSwitch),
        Entry("gedeployed", ["gedeploid", "gedeploijd"], category: .codeSwitch),
        Entry("mergen", ["mergun", "murgen"], category: .codeSwitch),
        Entry("committen", ["commiten", "kommitten"], category: .codeSwitch),
        Entry("gecommit", ["gekommit"], category: .codeSwitch),
        Entry("pushen", ["poeshen", "poesjen"], category: .codeSwitch),
        Entry("debuggen", ["debuggun", "diebuggen"], category: .codeSwitch),
        Entry("refactoren", ["refectoren", "riefactoren"], category: .codeSwitch),
        Entry("transcriben", ["transcryben"], category: .codeSwitch),
        Entry("reasonen", ["riesonen", "reesonen"], category: .codeSwitch),
        Entry("workflow", ["work flow", "werkflow"], category: .codeSwitch),
        Entry("feature", ["fietsjer", "fietsher"], category: .codeSwitch),
        Entry("release", ["rielies", "rieliese"], category: .codeSwitch),
        Entry("update", ["updeet"], category: .codeSwitch),
        Entry("framework", ["frame work", "freemwork"], category: .codeSwitch),
        Entry("repository", ["repositorie", "repozitory"], category: .codeSwitch),
        Entry("endpoint", ["end point", "endpoind"], category: .codeSwitch),
        Entry("pull request", ["pul request", "poel request"], category: .codeSwitch),
        Entry("merge conflict", ["merge conflickt"], category: .codeSwitch),
        Entry("open source", ["opensource", "open sauce"], category: .codeSwitch),
        Entry("fixen", ["fiksen", "fixsen"], category: .codeSwitch),
        Entry("gefixt", ["gefikst", "gefixed", "gefixd"], category: .codeSwitch),
        Entry("checken", ["tsjekken", "tjekken", "sjekken"], category: .codeSwitch),
        Entry("gecheckt", ["getsjekt", "getjekt", "gechecked"], category: .codeSwitch),
        Entry("sharen", ["sjeren", "sheren"], category: .codeSwitch),
        Entry("geshared", ["gesjeerd", "geshaard"], category: .codeSwitch),
        Entry("builden", ["bilden"], category: .codeSwitch),
        Entry("runnen", ["runnun"], category: .codeSwitch),
        Entry("scrollen", ["skrollen", "scrolen"], category: .codeSwitch),
        Entry("downloaden", ["downlowden", "daunloaden"], category: .codeSwitch),
        Entry("uploaden", ["uplowden", "uppploaden"], category: .codeSwitch),
        Entry("installen", ["instollen"], category: .codeSwitch),
        Entry("skippen", ["skipen"], category: .codeSwitch),
        Entry("prompten", ["promten", "prompen"], category: .codeSwitch),
        Entry("geprompt", ["gepromt", "geprompd"], category: .codeSwitch),
    ]
}
