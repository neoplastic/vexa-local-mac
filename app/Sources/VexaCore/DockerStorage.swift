import Foundation

// Parsing and classification for the Storage page. The rules mirror
// scripts/cleanup.sh (keep the two in step):
//  - "Current" Vexa images: vexaai/v012-* (pulled) and vexa/* (built locally).
//  - "Old 0.10" images: vexa-<name> with no namespace (but not vexa-v012*).
//  - Images the current .env/compose file or the bot reference are in use, and so
//    is any image a running container uses. Everything else from Vexa is removable.
//  - Untagged images only count as Vexa's when a Vexa container was made from them.
//  - Volumes vexa-v012_* hold the current meetings and transcripts: never removable.

// MARK: - Sizes

public enum ByteCount {
    private static let units: [(String, Double)] = [
        ("PB", 1e15), ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1),
    ]

    /// Parses Docker's human sizes ("6.57GB", "8.523kB", "0B", "799kB (virtual 4GB)").
    /// Docker uses decimal units. Returns nil for "N/A" or anything unreadable.
    public static func parse(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = .whitespaces
        guard let value = scanner.scanDouble() else { return nil }
        for (unit, factor) in units where scanner.scanString(unit) != nil {
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// "6.6 GB", "196 MB", "0 B" — decimal units, like Docker and Finder.
    public static func format(_ bytes: Int64) -> String {
        let names = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(max(bytes, 0))
        var i = 0
        while value >= 1000, i < names.count - 1 { value /= 1000; i += 1 }
        if i == 0 { return "\(Int(value)) B" }
        return String(format: value < 100 ? "%.1f %@" : "%.0f %@", value, names[i])
    }
}

// MARK: - Docker objects

public struct DockerImage: Equatable, Sendable {
    public var id: String           // "sha256:…"
    public var repository: String   // "<none>" when untagged
    public var tag: String          // "<none>" when untagged
    public var size: Int64
    public var uniqueSize: Int64?   // bytes not shared with any other image
    public var containers: Int
    public var created: String      // "6 weeks ago"

    public init(id: String, repository: String, tag: String, size: Int64, uniqueSize: Int64? = nil,
                containers: Int = 0, created: String = "") {
        self.id = id; self.repository = repository; self.tag = tag; self.size = size
        self.uniqueSize = uniqueSize; self.containers = containers; self.created = created
    }

    public var shortID: String {
        String((id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id).prefix(12))
    }
    public var hasName: Bool { repository != "<none>" }
    public var isTagged: Bool { hasName && tag != "<none>" }
    /// "repo:tag", or a description of an untagged image.
    public var displayName: String {
        if isTagged { return "\(repository):\(tag)" }
        return hasName ? "\(repository) (untagged \(shortID))" : "untagged \(shortID)"
    }
}

public struct DockerContainer: Equatable, Sendable {
    public var name: String
    public var imageID: String      // "sha256:…"
    public var imageRef: String     // what it was created from, e.g. "vexa/vexa-bot:local"
    public var state: String        // running, exited, created, …
    public var project: String      // compose project label, "" if none

    public init(name: String, imageID: String, imageRef: String, state: String, project: String = "") {
        self.name = name; self.imageID = imageID; self.imageRef = imageRef; self.state = state; self.project = project
    }

    public var isRunning: Bool { state == "running" }
    public var isMeetingBot: Bool { name.hasPrefix("vexa-mtg-") }
}

public struct DockerVolume: Equatable, Sendable {
    public var name: String
    public var size: Int64?
    public var links: Int?          // containers using it
    public var project: String

    public init(name: String, size: Int64?, links: Int? = nil, project: String = "") {
        self.name = name; self.size = size; self.links = links; self.project = project
    }
}

public struct DockerDiskUsage: Equatable, Sendable {
    public var images: [DockerImage]
    public var volumes: [DockerVolume]
    public var buildCache: Int64
    public var containerCount: Int

    public init(images: [DockerImage], volumes: [DockerVolume], buildCache: Int64, containerCount: Int = 0) {
        self.images = images; self.volumes = volumes; self.buildCache = buildCache; self.containerCount = containerCount
    }
}

/// Colima's VM disk: total from `colima list`, use from `df` inside the VM.
public struct VMDisk: Equatable, Sendable {
    public var total: Int64
    public var used: Int64?
    public var available: Int64?
    public init(total: Int64, used: Int64? = nil, available: Int64? = nil) {
        self.total = total; self.used = used; self.available = available
    }
}

// MARK: - Parsing

public enum DockerParse {
    public struct ParseError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Container inspect template whose output `containers(_:)` reads.
    public static let containerFormat =
        #"{"name":{{json .Name}},"image":{{json .Image}},"ref":{{json .Config.Image}},"state":{{json .State.Status}},"project":{{json (index .Config.Labels "com.docker.compose.project")}}}"#

    /// Output of `docker system df -v --format '{{json .}}'`.
    public static func diskUsage(_ text: String) throws -> DockerDiskUsage {
        struct Image: Decodable {
            var ID: String; var Repository: String?; var Tag: String?
            var Size: String?; var UniqueSize: String?; var Containers: String?; var CreatedSince: String?
        }
        struct Volume: Decodable { var Name: String; var Size: String?; var Links: String?; var Labels: String? }
        struct Cache: Decodable { var Size: String?; var Shared: String? }
        struct Root: Decodable { var Images: [Image]?; var Volumes: [Volume]?; var BuildCache: [Cache]?; var Containers: [Ignored]? }
        struct Ignored: Decodable {}

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw ParseError(message: "Docker returned no disk usage data.")
        }
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) } catch {
            throw ParseError(message: "Could not read Docker's disk usage: \(error.localizedDescription)")
        }
        let images = (root.Images ?? []).map {
            DockerImage(id: $0.ID, repository: $0.Repository ?? "<none>", tag: $0.Tag ?? "<none>",
                        size: ByteCount.parse($0.Size) ?? 0, uniqueSize: ByteCount.parse($0.UniqueSize),
                        containers: Int($0.Containers ?? "") ?? 0, created: $0.CreatedSince ?? "")
        }
        let volumes = (root.Volumes ?? []).map {
            DockerVolume(name: $0.Name, size: ByteCount.parse($0.Size), links: Int($0.Links ?? ""),
                         project: label("com.docker.compose.project", in: $0.Labels ?? "") ?? "")
        }
        // Shared cache records are counted by the records that own them.
        let cache = (root.BuildCache ?? []).filter { $0.Shared != "true" }
            .reduce(Int64(0)) { $0 + (ByteCount.parse($1.Size) ?? 0) }
        return DockerDiskUsage(images: images, volumes: volumes, buildCache: cache,
                               containerCount: root.Containers?.count ?? 0)
    }

    /// One JSON object per line, from `docker inspect --format <containerFormat> $(docker ps -aq)`.
    public static func containers(_ text: String) -> [DockerContainer] {
        struct Row: Decodable { var name: String; var image: String; var ref: String?; var state: String; var project: String? }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            let name = row.name.hasPrefix("/") ? String(row.name.dropFirst()) : row.name
            return DockerContainer(name: name, imageID: row.image, imageRef: row.ref ?? "", state: row.state,
                                   project: row.project ?? "")
        }
    }

    /// Output of `scripts/cleanup.sh --referenced`: one image reference per line.
    public static func references(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") })
    }

    /// Disk size of `profile` from `colima list --json` (one JSON object per line).
    public static func colimaDisk(_ text: String, profile: String) -> Int64? {
        struct Row: Decodable { var name: String; var disk: Int64? }
        for line in text.split(whereSeparator: \.isNewline) {
            if let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), row.name == profile {
                return row.disk
            }
        }
        return nil
    }

    /// (size, used, available) in bytes from `df -k <path>` output (last line).
    public static func dfKilobytes(_ text: String) -> (size: Int64, used: Int64, available: Int64)? {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.hasPrefix("Filesystem") })
        else { return nil }
        let cols = line.split(whereSeparator: \.isWhitespace)
        guard cols.count >= 4, let size = Int64(cols[1]), let used = Int64(cols[2]), let avail = Int64(cols[3])
        else { return nil }
        return (size * 1024, used * 1024, avail * 1024)
    }

    /// Value of `key` in Docker's "k1=v1,k2=v2" label string.
    static func label(_ key: String, in labels: String) -> String? {
        for pair in labels.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == key { return String(parts[1]) }
        }
        return nil
    }
}

// MARK: - Classification

public enum VexaImageKind: String, CaseIterable, Sendable {
    case inUse      // referenced by the current setup, or used by a running container
    case unused     // superseded Vexa image (older tag/digest, untagged Vexa build)
    case leftover   // other locally built vexa/* tags, e.g. test builds
    case old        // the old Vexa 0.10 stack
    case other      // not Vexa's: never touched
}

public enum VexaVolumeKind: String, Sendable {
    case current    // vexa-v012_*: the current stack's database and recordings
    case old        // the old Vexa 0.10 stack
    case other
}

public enum VexaStorageRules {
    public static let currentProject = "vexa-v012"
    public static let oldProject = "vexa"

    /// "docker.io/library/postgres" → "postgres:latest"; drops any "@sha256:…".
    public static func normalize(_ reference: String) -> String {
        var ref = reference.trimmingCharacters(in: .whitespaces)
        for prefix in ["docker.io/library/", "docker.io/", "library/"] where ref.hasPrefix(prefix) {
            ref.removeFirst(prefix.count)
        }
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        let lastComponent = ref.split(separator: "/").last ?? ""
        if !lastComponent.contains(":") { ref += ":latest" }
        return ref
    }

    static func repository(of reference: String) -> String {
        let ref = normalize(reference)
        guard let colon = ref.lastIndex(of: ":") else { return ref }
        return String(ref[..<colon])
    }

    public static func isCurrentRepository(_ repo: String) -> Bool {
        repo.hasPrefix("vexaai/v012-") || repo.hasPrefix("vexa/")
    }

    public static func isOldRepository(_ repo: String) -> Bool {
        repo.hasPrefix("vexa-") && !repo.contains("/") && !repo.hasPrefix("vexa-v012")
    }

    public static func isVexaContainer(_ c: DockerContainer) -> Bool {
        let repo = repository(of: c.imageRef)
        return c.name.hasPrefix("vexa-") || isCurrentRepository(repo) || isOldRepository(repo)
    }

    /// `referenced` is nil when the compose file couldn't be read: then no current
    /// Vexa image is treated as removable.
    public static func classify(_ image: DockerImage, referenced: Set<String>?,
                                containers: [DockerContainer]) -> VexaImageKind {
        let users = containers.filter { $0.imageID == image.id }
        let running = users.contains(where: \.isRunning)
        if !image.hasName {
            // Owner unknown: Vexa's only if a Vexa container was made from it.
            guard users.contains(where: isVexaContainer) else { return .other }
            return running ? .inUse : .unused
        }
        // Referenced images include the stack's third-party ones (postgres, valkey, …).
        let refs = referenced ?? []
        let digests = Set(refs.compactMap { $0.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) })
        if digests.contains(image.id) || digests.contains("sha256:" + image.id) { return .inUse }
        let normalized = Set(refs.map(normalize))
        if image.isTagged, normalized.contains(normalize("\(image.repository):\(image.tag)")) { return .inUse }
        let current = isCurrentRepository(image.repository), old = isOldRepository(image.repository)
        guard current || old else { return .other }   // never touched, running or not
        if running { return .inUse }
        if current, referenced == nil { return .inUse }
        if old { return .old }
        return image.repository.hasPrefix("vexa/") && image.isTagged ? .leftover : .unused
    }

    public static func classify(_ volume: DockerVolume) -> VexaVolumeKind {
        if volume.name.hasPrefix("vexa-v012") || volume.project == currentProject { return .current }
        if volume.name.hasPrefix("vexa_") || volume.name == "vexa-bot-screenshots" || volume.project == oldProject {
            return .old
        }
        return .other
    }
}

// MARK: - Report

public struct ClassifiedImage: Equatable, Identifiable, Sendable {
    public var image: DockerImage
    public var kind: VexaImageKind
    public var id: String { image.id + "|" + image.displayName }
}

public struct ClassifiedVolume: Equatable, Identifiable, Sendable {
    public var volume: DockerVolume
    public var kind: VexaVolumeKind
    public var id: String { volume.name }
}

/// Bytes a removal would free: at least the layers unique to those images, at most their full size.
public struct ReclaimEstimate: Equatable, Sendable {
    public var atLeast: Int64
    public var atMost: Int64
    public var text: String {
        atLeast == atMost ? ByteCount.format(atMost)
            : "\(ByteCount.format(atLeast))–\(ByteCount.format(atMost))"
    }
}

public struct VexaStorageReport: Equatable, Sendable {
    public var images: [ClassifiedImage]
    public var volumes: [ClassifiedVolume]
    public var stoppedBots: [DockerContainer]
    public var buildCache: Int64
    public var referencesKnown: Bool

    public init(usage: DockerDiskUsage, containers: [DockerContainer], referenced: Set<String>?) {
        var images = usage.images.map {
            ClassifiedImage(image: $0, kind: VexaStorageRules.classify($0, referenced: referenced, containers: containers))
        }
        // An untagged row that is another name for an image we keep must stay.
        let keptIDs = Set(images.filter { $0.kind == .inUse || $0.kind == .other }.map(\.image.id))
        for i in images.indices where !images[i].image.isTagged && images[i].kind != .inUse
            && images[i].kind != .other && keptIDs.contains(images[i].image.id) {
            images[i].kind = .inUse
        }
        self.images = images.sorted { $0.image.size > $1.image.size }
        volumes = usage.volumes.map { ClassifiedVolume(volume: $0, kind: VexaStorageRules.classify($0)) }
            .sorted { $0.volume.name < $1.volume.name }
        stoppedBots = containers.filter { $0.isMeetingBot && !$0.isRunning }
        buildCache = usage.buildCache
        referencesKnown = referenced != nil
    }

    public func images(_ kinds: VexaImageKind...) -> [ClassifiedImage] {
        images.filter { kinds.contains($0.kind) }
    }

    public func volumes(_ kind: VexaVolumeKind) -> [ClassifiedVolume] { volumes.filter { $0.kind == kind } }

    /// Sum of image sizes; images listed under several names count once.
    public func size(of list: [ClassifiedImage]) -> Int64 {
        var seen = Set<String>()
        return list.reduce(0) { seen.insert($1.image.id).inserted ? $0 + $1.image.size : $0 }
    }

    public func estimate(for list: [ClassifiedImage]) -> ReclaimEstimate {
        var seen = Set<String>()
        var low: Int64 = 0, high: Int64 = 0
        for item in list where seen.insert(item.image.id).inserted {
            high += item.image.size
            low += min(item.image.uniqueSize ?? 0, item.image.size)
        }
        return ReclaimEstimate(atLeast: low, atMost: high)
    }

    /// What "Remove unused Vexa images" (cleanup.sh --images) removes.
    public var removableImages: [ClassifiedImage] { images(.unused, .leftover) }
    public var oldImages: [ClassifiedImage] { images(.old) }
    public var oldVolumes: [ClassifiedVolume] { volumes(.old) }
    public var currentVolumes: [ClassifiedVolume] { volumes(.current) }

    public var oldDataSize: Int64 {
        size(of: oldImages) + oldVolumes.reduce(0) { $0 + ($1.volume.size ?? 0) }
    }

    public var vexaImagesSize: Int64 { size(of: images.filter { $0.kind != .other }) }
    public var otherImagesSize: Int64 { size(of: images(.other)) }
    public var vexaVolumesSize: Int64 {
        volumes.filter { $0.kind != .other }.reduce(0) { $0 + ($1.volume.size ?? 0) }
    }
}

// MARK: - Quitting

/// What is running when the app is asked to quit, and what that means.
public struct RunningVexa: Equatable, Sendable {
    public var dockerReachable: Bool
    public var runningContainers: [String]   // names, from `docker ps --format '{{.Names}}'`
    public var whisperRunning: Bool
    public var unfinishedSessions: Int        // bots the app is still following

    public init(dockerReachable: Bool, runningContainers: [String], whisperRunning: Bool, unfinishedSessions: Int) {
        self.dockerReachable = dockerReachable; self.runningContainers = runningContainers
        self.whisperRunning = whisperRunning; self.unfinishedSessions = unfinishedSessions
    }

    public var stackContainers: [String] {
        runningContainers.filter { $0.hasPrefix(VexaStorageRules.currentProject + "-") }
    }
    public var meetingBots: [String] { runningContainers.filter { $0.hasPrefix("vexa-mtg-") } }

    /// Nothing to stop: quit straight away.
    public var needsStopping: Bool { !stackContainers.isEmpty || !meetingBots.isEmpty || whisperRunning }

    /// Meetings that stopping would cut short. Sessions only count while Vexa is up:
    /// with Docker down no bot can be transcribing.
    public var meetingsInProgress: Int {
        guard dockerReachable, !stackContainers.isEmpty || !meetingBots.isEmpty else { return 0 }
        return max(meetingBots.count, unfinishedSessions)
    }
}
