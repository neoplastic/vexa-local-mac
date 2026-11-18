import XCTest
@testable import VexaCore

/// Fixtures are trimmed copies of real `docker` / `colima` output.
final class DockerStorageTests: XCTestCase {
    // `docker system df -v --format '{{json .}}'`
    static let diskUsageJSON = #"""
    {"Images":[
    {"Containers":"1","CreatedSince":"12 minutes ago","ID":"sha256:ae85f576ba6931cefd6252e2cb24542dcf5187e99de1bf445ef6a0269a2344df","Repository":"vexa/vexa-bot","SharedSize":"3.879GB","Size":"6.57GB","Tag":"local-amd64","UniqueSize":"2.686GB"},
    {"Containers":"0","CreatedSince":"14 minutes ago","ID":"sha256:c5fa8dc7a91dadc8fe2cf061d92f659e9bb88ead2af24b1a6f6334dc5f9ff3d6","Repository":"vexa/meet-join-env","SharedSize":"3.879GB","Size":"3.88GB","Tag":"dev-amd64","UniqueSize":"8.523kB"},
    {"Containers":"0","CreatedSince":"20 minutes ago","ID":"sha256:64e27402dc15b3f27f95c3104d802fa67d02a7d75e42ad0523b2541eb0f20916","Repository":"vexa/vexa-bot","SharedSize":"3.769GB","Size":"5.37GB","Tag":"local","UniqueSize":"1.599GB"},
    {"Containers":"0","CreatedSince":"34 minutes ago","ID":"sha256:2c2dc1590919da0b9f7828e3f8f9a5e21003be809ab565aa3a3120f1bdec211e","Repository":"vexa/meet-join-env","SharedSize":"3.769GB","Size":"3.77GB","Tag":"dev","UniqueSize":"8.517kB"},
    {"Containers":"0","CreatedSince":"54 minutes ago","ID":"sha256:e1cd2d7779b44770b0a8aff8954e566ac7d302ca4c75c621d259addd7e1603a9","Repository":"vexa-bot","SharedSize":"32B","Size":"3.48GB","Tag":"dev","UniqueSize":"3.481GB"},
    {"Containers":"0","CreatedSince":"About an hour ago","ID":"sha256:49212bbe0bb02ac22f11763b6d6c9a2cef6fff9ca897512a10d4d2c9f01400fa","Repository":"vexa-api-gateway","SharedSize":"312.1MB","Size":"359MB","Tag":"latest","UniqueSize":"46.54MB"},
    {"Containers":"0","CreatedSince":"5 days ago","ID":"sha256:23799e521dee9265a8b388ecf3bc0f1eaa34b95be67f5a76af4f8f6adb44c720","Repository":"postgres","SharedSize":"13.5MB","Size":"409MB","Tag":"15-alpine","UniqueSize":"395.4MB"},
    {"Containers":"1","CreatedSince":"5 days ago","ID":"sha256:a77aa70e641402a21411b92b721c58d10f23b50ae5fdd2333efd22d166e1e5f7","Repository":"postgres","SharedSize":"13.5MB","Size":"416MB","Tag":"17-alpine","UniqueSize":"402.4MB"},
    {"Containers":"1","CreatedSince":"2 months ago","ID":"sha256:2e76319812f28adbb6bc328ac0a7484d3826924a9d38a9dd9599dd190fbb0f19","Repository":"vexaai/v012-gateway","SharedSize":"0B","Size":"376MB","Tag":"v012","UniqueSize":"376MB"},
    {"Containers":"0","CreatedSince":"3 months ago","ID":"sha256:1111111111111111111111111111111111111111111111111111111111111111","Repository":"vexaai/v012-gateway","SharedSize":"0B","Size":"370MB","Tag":"<none>","UniqueSize":"300MB"},
    {"Containers":"0","CreatedSince":"2 months ago","ID":"sha256:a1120b24765ff6b1c86c5f9ddee35b5e71fdbb9543a23b918b278373ad705022","Repository":"vexaai/v012-agent-worker","SharedSize":"N/A","Size":"1.21GB","Tag":"v012","UniqueSize":"N/A"},
    {"Containers":"1","CreatedSince":"2 months ago","ID":"sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499","Repository":"versity/versitygw","SharedSize":"0B","Size":"93.3MB","Tag":"<none>","UniqueSize":"93.3MB"},
    {"Containers":"2","CreatedSince":"3 days ago","ID":"sha256:bf096dffde82a0cb3cb3cd45e7f21963526e0db52e06d7bc69c9bf44954dd5ea","Repository":"<none>","SharedSize":"0B","Size":"4.05GB","Tag":"<none>","UniqueSize":"1.2GB"},
    {"Containers":"0","CreatedSince":"1 year ago","ID":"sha256:9999999999999999999999999999999999999999999999999999999999999999","Repository":"<none>","SharedSize":"0B","Size":"120MB","Tag":"<none>","UniqueSize":"120MB"}
    ],
    "Containers":[{"ID":"029cacb1d20b","Image":"vexaai/v012-runtime:v012","Names":"vexa-v012-runtime-1","Size":"9.56MB","State":"running"}],
    "Volumes":[
    {"Driver":"local","Labels":"","Links":"0","Name":"vexa-bot-screenshots","Size":"28.45kB"},
    {"Driver":"local","Labels":"com.docker.compose.config-hash=725a,com.docker.compose.project=vexa,com.docker.compose.version=2.40.1,com.docker.compose.volume=postgres-data","Links":"0","Name":"vexa_postgres-data","Size":"49.37MB"},
    {"Driver":"local","Labels":"com.docker.compose.project=vexa-v012,com.docker.compose.version=2.40.1,com.docker.compose.volume=postgres-data","Links":"1","Name":"vexa-v012_postgres-data","Size":"49.8MB"},
    {"Driver":"local","Labels":"com.docker.compose.project=vexa-v012,com.docker.compose.volume=agent-workspaces","Links":"1","Name":"vexa-v012_agent-workspaces","Size":"0B"},
    {"Driver":"local","Labels":"","Links":"0","Name":"someone-elses-data","Size":"1GB"}
    ],
    "BuildCache":[
    {"CacheType":"regular","ID":"a","InUse":"false","Shared":"false","Size":"196MB"},
    {"CacheType":"regular","ID":"b","InUse":"false","Shared":"true","Size":"24GB"},
    {"CacheType":"regular","ID":"c","InUse":"false","Shared":"false","Size":"17.46GB"}
    ]}
    """#

    // `docker inspect --format <DockerParse.containerFormat> $(docker ps -aq)`
    static let containersText = #"""
    {"name":"/vexa-v012-runtime-1","image":"sha256:a1f6448fbb380b9433364e8b572ec25a12aa4f274bf403f1d83a89cbf5812f2d","ref":"vexaai/v012-runtime:v012","state":"running","project":"vexa-v012"}
    {"name":"/vexa-v012-gateway-1","image":"sha256:2e76319812f28adbb6bc328ac0a7484d3826924a9d38a9dd9599dd190fbb0f19","ref":"vexaai/v012-gateway:v012","state":"running","project":"vexa-v012"}
    {"name":"/vexa-v012-postgres-1","image":"sha256:a77aa70e641402a21411b92b721c58d10f23b50ae5fdd2333efd22d166e1e5f7","ref":"postgres:17-alpine","state":"running","project":"vexa-v012"}
    {"name":"/vexa-v012-storage-1","image":"sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499","ref":"versity/versitygw:v1.8.0","state":"running","project":"vexa-v012"}
    {"name":"/vexa-mtg-6-91a3c48d","image":"sha256:ae85f576ba6931cefd6252e2cb24542dcf5187e99de1bf445ef6a0269a2344df","ref":"vexa/vexa-bot:local-amd64","state":"exited","project":""}
    {"name":"/vexa-mtg-2-2b8bd625","image":"sha256:bf096dffde82a0cb3cb3cd45e7f21963526e0db52e06d7bc69c9bf44954dd5ea","ref":"vexa/vexa-bot:local","state":"exited","project":""}
    {"name":"/vexa-mtg-9-aaaa","image":"sha256:64e27402dc15b3f27f95c3104d802fa67d02a7d75e42ad0523b2541eb0f20916","ref":"vexa/vexa-bot:local","state":"running","project":""}
    not json
    """#

    // `scripts/cleanup.sh --referenced`
    static let referencedText = """
    postgres:17-alpine
    valkey/valkey:8-alpine
    versity/versitygw:v1.8.0@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499
    vexa/meet-join-env:dev
    vexa/vexa-bot:local
    vexaai/dashboard:0.10.6.3.14
    vexaai/v012-agent-worker:v012
    vexaai/v012-gateway:v012
    vexaai/v012-runtime:v012

    """

    private func report(referenced: Set<String>? = DockerParse.references(referencedText)) throws -> VexaStorageReport {
        VexaStorageReport(usage: try DockerParse.diskUsage(Self.diskUsageJSON),
                          containers: DockerParse.containers(Self.containersText), referenced: referenced)
    }

    private func kind(_ name: String, in report: VexaStorageReport) -> VexaImageKind? {
        report.images.first { $0.image.displayName == name }?.kind
    }

    // MARK: Sizes

    func testParsesDockerSizes() {
        XCTAssertEqual(ByteCount.parse("6.57GB"), 6_570_000_000)
        XCTAssertEqual(ByteCount.parse("8.523kB"), 8_523)
        XCTAssertEqual(ByteCount.parse("32B"), 32)
        XCTAssertEqual(ByteCount.parse("0B"), 0)
        XCTAssertEqual(ByteCount.parse("196MB"), 196_000_000)
        XCTAssertEqual(ByteCount.parse("1.5TB"), 1_500_000_000_000)
        XCTAssertEqual(ByteCount.parse("799kB (virtual 4.05GB)"), 799_000)
        XCTAssertEqual(ByteCount.parse("12 MB"), 12_000_000)
        XCTAssertNil(ByteCount.parse("N/A"))
        XCTAssertNil(ByteCount.parse(""))
        XCTAssertNil(ByteCount.parse(nil))
        XCTAssertNil(ByteCount.parse("12 parsecs"))
    }

    func testFormatsSizes() {
        XCTAssertEqual(ByteCount.format(0), "0 B")
        XCTAssertEqual(ByteCount.format(999), "999 B")
        XCTAssertEqual(ByteCount.format(8_523), "8.5 kB")
        XCTAssertEqual(ByteCount.format(196_000_000), "196 MB")
        XCTAssertEqual(ByteCount.format(6_570_000_000), "6.6 GB")
        XCTAssertEqual(ByteCount.format(17_660_000_000), "17.7 GB")
        XCTAssertEqual(ByteCount.format(-5), "0 B")
    }

    // MARK: Parsing

    func testParsesDiskUsage() throws {
        let usage = try DockerParse.diskUsage(Self.diskUsageJSON)
        XCTAssertEqual(usage.images.count, 14)
        XCTAssertEqual(usage.containerCount, 1)
        let bot = try XCTUnwrap(usage.images.first)
        XCTAssertEqual(bot.repository, "vexa/vexa-bot")
        XCTAssertEqual(bot.tag, "local-amd64")
        XCTAssertEqual(bot.size, 6_570_000_000)
        XCTAssertEqual(bot.uniqueSize, 2_686_000_000)
        XCTAssertEqual(bot.containers, 1)
        XCTAssertEqual(bot.shortID, "ae85f576ba69")
        XCTAssertNil(usage.images.first { $0.repository == "vexaai/v012-agent-worker" }?.uniqueSize)
        // Shared cache records are not double counted.
        XCTAssertEqual(usage.buildCache, 196_000_000 + 17_460_000_000)
        let old = try XCTUnwrap(usage.volumes.first { $0.name == "vexa_postgres-data" })
        XCTAssertEqual(old.project, "vexa")
        XCTAssertEqual(old.size, 49_370_000)
        XCTAssertEqual(old.links, 0)
    }

    func testDiskUsageErrors() {
        XCTAssertThrowsError(try DockerParse.diskUsage(""))
        XCTAssertThrowsError(try DockerParse.diskUsage("Cannot connect to the Docker daemon"))
        XCTAssertEqual(try DockerParse.diskUsage("{}").images, [])
    }

    func testParsesContainers() {
        let containers = DockerParse.containers(Self.containersText)
        XCTAssertEqual(containers.count, 7)   // the bad line is skipped
        XCTAssertEqual(containers[0].name, "vexa-v012-runtime-1")
        XCTAssertEqual(containers[0].project, "vexa-v012")
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertTrue(containers[4].isMeetingBot)
        XCTAssertFalse(containers[4].isRunning)
        XCTAssertEqual(containers[4].project, "")
    }

    func testParsesReferences() {
        let refs = DockerParse.references(Self.referencedText + "Warning: something odd\n")
        XCTAssertEqual(refs.count, 9)
        XCTAssertTrue(refs.contains("vexa/vexa-bot:local"))
    }

    func testParsesColima() {
        let list = """
        {"name":"default","status":"Running","arch":"aarch64","cpus":6,"memory":6442450944,"disk":107374182400,"runtime":"docker"}
        {"name":"work","status":"Stopped","arch":"aarch64","cpus":2,"memory":2147483648,"disk":64424509440,"runtime":"docker"}
        """
        XCTAssertEqual(DockerParse.colimaDisk(list, profile: "default"), 107_374_182_400)
        XCTAssertEqual(DockerParse.colimaDisk(list, profile: "work"), 64_424_509_440)
        XCTAssertNil(DockerParse.colimaDisk(list, profile: "missing"))
        XCTAssertNil(DockerParse.colimaDisk("colima: command not found", profile: "default"))

        let df = """
        Filesystem     1K-blocks     Used Available Use% Mounted on
        /dev/vdb1      102626232 54119044  43248924  56% /var/lib/docker
        """
        let parsed = DockerParse.dfKilobytes(df)
        XCTAssertEqual(parsed?.size, 102_626_232 * 1024)
        XCTAssertEqual(parsed?.used, 54_119_044 * 1024)
        XCTAssertEqual(parsed?.available, 43_248_924 * 1024)
        XCTAssertNil(DockerParse.dfKilobytes("ssh: connect failed"))
    }

    // MARK: Rules

    func testNormalizesReferences() {
        XCTAssertEqual(VexaStorageRules.normalize("postgres"), "postgres:latest")
        XCTAssertEqual(VexaStorageRules.normalize("docker.io/library/postgres:17-alpine"), "postgres:17-alpine")
        XCTAssertEqual(VexaStorageRules.normalize("docker.io/vexaai/v012-mcp:v012"), "vexaai/v012-mcp:v012")
        XCTAssertEqual(VexaStorageRules.normalize("versity/versitygw:v1.8.0@sha256:abc"), "versity/versitygw:v1.8.0")
        XCTAssertEqual(VexaStorageRules.normalize("localhost:5000/vexa/bot"), "localhost:5000/vexa/bot:latest")
    }

    func testRepositoryFamilies() {
        XCTAssertTrue(VexaStorageRules.isCurrentRepository("vexaai/v012-gateway"))
        XCTAssertTrue(VexaStorageRules.isCurrentRepository("vexa/vexa-bot"))
        XCTAssertFalse(VexaStorageRules.isCurrentRepository("vexaai/dashboard"))
        XCTAssertTrue(VexaStorageRules.isOldRepository("vexa-whisperlive"))
        XCTAssertTrue(VexaStorageRules.isOldRepository("vexa-bot"))
        XCTAssertFalse(VexaStorageRules.isOldRepository("vexa-v012-gateway"))
        XCTAssertFalse(VexaStorageRules.isOldRepository("vexa/vexa-bot"))
        XCTAssertFalse(VexaStorageRules.isOldRepository("vexaa-thing/x"))
        XCTAssertFalse(VexaStorageRules.isOldRepository("postgres"))
    }

    func testClassifiesImages() throws {
        let r = try report()
        XCTAssertEqual(kind("vexaai/v012-gateway:v012", in: r), .inUse)        // running
        XCTAssertEqual(kind("vexaai/v012-agent-worker:v012", in: r), .inUse)   // referenced, not running
        XCTAssertEqual(kind("vexa/vexa-bot:local", in: r), .inUse)             // the bot image
        XCTAssertEqual(kind("vexa/meet-join-env:dev", in: r), .inUse)
        XCTAssertEqual(kind("vexa/vexa-bot:local-amd64", in: r), .leftover)    // only a stopped bot uses it
        XCTAssertEqual(kind("vexa/meet-join-env:dev-amd64", in: r), .leftover)
        XCTAssertEqual(kind("vexaai/v012-gateway (untagged 111111111111)", in: r), .unused)  // superseded pull
        XCTAssertEqual(kind("untagged bf096dffde82", in: r), .unused)          // old bot build, made into a vexa-mtg container
        XCTAssertEqual(kind("untagged 999999999999", in: r), .other)           // owner unknown: left alone
        XCTAssertEqual(kind("vexa-bot:dev", in: r), .old)
        XCTAssertEqual(kind("vexa-api-gateway:latest", in: r), .old)
        XCTAssertEqual(kind("postgres:15-alpine", in: r), .other)              // not Vexa's, even if unused
        XCTAssertEqual(kind("postgres:17-alpine", in: r), .inUse)
        XCTAssertEqual(kind("versity/versitygw (untagged 30292fc2eeac)", in: r), .inUse)
    }

    func testRunningContainerAlwaysKeepsItsImage() {
        let image = DockerImage(id: "sha256:abc", repository: "vexa/vexa-bot", tag: "test", size: 1)
        let running = DockerContainer(name: "vexa-mtg-1", imageID: "sha256:abc", imageRef: "vexa/vexa-bot:test", state: "running")
        XCTAssertEqual(VexaStorageRules.classify(image, referenced: [], containers: [running]), .inUse)
        XCTAssertEqual(VexaStorageRules.classify(image, referenced: [], containers: []), .leftover)
        // Old 0.10 images in use by a running container are kept too.
        let old = DockerImage(id: "sha256:old", repository: "vexa-bot", tag: "dev", size: 1)
        let oldBot = DockerContainer(name: "x", imageID: "sha256:old", imageRef: "vexa-bot:dev", state: "running")
        XCTAssertEqual(VexaStorageRules.classify(old, referenced: [], containers: [oldBot]), .inUse)
        // Someone else's running image is not Vexa's: it stays "other".
        let nginx = DockerImage(id: "sha256:ng", repository: "nginx", tag: "latest", size: 1)
        let web = DockerContainer(name: "web", imageID: "sha256:ng", imageRef: "nginx", state: "running")
        XCTAssertEqual(VexaStorageRules.classify(nginx, referenced: [], containers: [web]), .other)
        // An untagged image a running bot uses is in use; one only another app uses is not Vexa's.
        let untagged = DockerImage(id: "sha256:u", repository: "<none>", tag: "<none>", size: 1)
        let bot = DockerContainer(name: "vexa-mtg-5-x", imageID: "sha256:u", imageRef: "vexa/vexa-bot:local", state: "running")
        XCTAssertEqual(VexaStorageRules.classify(untagged, referenced: [], containers: [bot]), .inUse)
        let other = DockerContainer(name: "web", imageID: "sha256:u", imageRef: "sha256:u", state: "exited")
        XCTAssertEqual(VexaStorageRules.classify(untagged, referenced: [], containers: [other]), .other)
    }

    func testUnknownReferencesKeepCurrentImages() throws {
        let r = try report(referenced: nil)
        XCTAssertFalse(r.referencesKnown)
        XCTAssertEqual(kind("vexa/vexa-bot:local-amd64", in: r), .inUse)
        XCTAssertEqual(kind("vexaai/v012-gateway (untagged 111111111111)", in: r), .inUse)
        XCTAssertEqual(kind("vexa-bot:dev", in: r), .old)   // 0.10 images don't depend on the compose file
        XCTAssertTrue(r.removableImages.allSatisfy { $0.image.repository == "<none>" })
    }

    func testUntaggedAliasOfKeptImageStays() {
        let tagged = DockerImage(id: "sha256:same", repository: "vexaai/v012-mcp", tag: "v012", size: 100)
        let alias = DockerImage(id: "sha256:same", repository: "vexaai/v012-mcp", tag: "<none>", size: 100)
        let usage = DockerDiskUsage(images: [tagged, alias], volumes: [], buildCache: 0)
        let r = VexaStorageReport(usage: usage, containers: [], referenced: ["vexaai/v012-mcp:v012"])
        XCTAssertTrue(r.images.allSatisfy { $0.kind == .inUse })
        XCTAssertTrue(r.removableImages.isEmpty)
    }

    func testReferencedByDigest() {
        let image = DockerImage(id: "sha256:30292f", repository: "vexaai/v012-flows", tag: "<none>", size: 1)
        XCTAssertEqual(VexaStorageRules.classify(image, referenced: ["vexaai/v012-flows:v012@sha256:30292f"],
                                                 containers: []), .inUse)
    }

    func testClassifiesVolumes() throws {
        let r = try report()
        XCTAssertEqual(r.currentVolumes.map(\.volume.name), ["vexa-v012_agent-workspaces", "vexa-v012_postgres-data"])
        XCTAssertEqual(r.oldVolumes.map(\.volume.name), ["vexa-bot-screenshots", "vexa_postgres-data"])
        XCTAssertEqual(r.volumes(.other).map(\.volume.name), ["someone-elses-data"])
        // Even an unlabelled vexa-v012 volume counts as current data.
        XCTAssertEqual(VexaStorageRules.classify(DockerVolume(name: "vexa-v012_x", size: 0)), .current)
        XCTAssertEqual(VexaStorageRules.classify(DockerVolume(name: "data", size: 0, project: "vexa")), .old)
    }

    // MARK: Report

    func testReportTotalsAndEstimates() throws {
        let r = try report()
        XCTAssertEqual(Set(r.removableImages.map(\.image.displayName)), [
            "vexa/vexa-bot:local-amd64", "vexa/meet-join-env:dev-amd64",
            "vexaai/v012-gateway (untagged 111111111111)", "untagged bf096dffde82",
        ])
        let estimate = r.estimate(for: r.removableImages)
        XCTAssertEqual(estimate.atMost, 6_570_000_000 + 3_880_000_000 + 370_000_000 + 4_050_000_000)
        XCTAssertEqual(estimate.atLeast, 2_686_000_000 + 8_523 + 300_000_000 + 1_200_000_000)
        XCTAssertEqual(estimate.text, "4.2 GB–14.9 GB")
        XCTAssertEqual(ReclaimEstimate(atLeast: 5, atMost: 5).text, "5 B")

        XCTAssertEqual(r.oldImages.count, 2)
        XCTAssertEqual(r.oldDataSize, 3_480_000_000 + 359_000_000 + 28_450 + 49_370_000)
        XCTAssertEqual(r.otherImagesSize, 409_000_000 + 120_000_000)
        XCTAssertEqual(r.vexaVolumesSize, 28_450 + 49_370_000 + 49_800_000)
        XCTAssertEqual(r.buildCache, 17_656_000_000)
        XCTAssertEqual(r.stoppedBots.map(\.name), ["vexa-mtg-6-91a3c48d", "vexa-mtg-2-2b8bd625"])
        XCTAssertEqual(r.images.first?.image.size, 6_570_000_000)   // largest first
    }

    // MARK: Quitting

    func testQuitWithNothingRunning() {
        let idle = RunningVexa(dockerReachable: true, runningContainers: ["some-other-app"], whisperRunning: false,
                               unfinishedSessions: 0)
        XCTAssertFalse(idle.needsStopping)
        XCTAssertEqual(idle.meetingsInProgress, 0)
    }

    func testQuitWithStackUp() {
        let up = RunningVexa(dockerReachable: true,
                             runningContainers: ["vexa-v012-gateway-1", "vexa-v012-postgres-1", "other"],
                             whisperRunning: true, unfinishedSessions: 0)
        XCTAssertTrue(up.needsStopping)
        XCTAssertEqual(up.stackContainers.count, 2)
        XCTAssertEqual(up.meetingsInProgress, 0)
    }

    func testQuitCountsMeetings() {
        let bots = RunningVexa(dockerReachable: true,
                               runningContainers: ["vexa-v012-runtime-1", "vexa-mtg-3-ab", "vexa-mtg-4-cd"],
                               whisperRunning: true, unfinishedSessions: 1)
        XCTAssertEqual(bots.meetingsInProgress, 2)
        // A bot that is still starting shows up as a session before its container runs.
        let starting = RunningVexa(dockerReachable: true, runningContainers: ["vexa-v012-runtime-1"],
                                   whisperRunning: false, unfinishedSessions: 1)
        XCTAssertEqual(starting.meetingsInProgress, 1)
    }

    func testQuitWithDockerDown() {
        let whisperOnly = RunningVexa(dockerReachable: false, runningContainers: [], whisperRunning: true,
                                      unfinishedSessions: 3)
        XCTAssertTrue(whisperOnly.needsStopping)        // still stop the native Whisper server
        XCTAssertEqual(whisperOnly.meetingsInProgress, 0)   // stale sessions can't be transcribing
        let nothing = RunningVexa(dockerReachable: false, runningContainers: [], whisperRunning: false,
                                  unfinishedSessions: 3)
        XCTAssertFalse(nothing.needsStopping)
    }

    func testImagesWithSeveralNamesCountOnce() {
        let a = DockerImage(id: "sha256:x", repository: "vexa/vexa-bot", tag: "a", size: 100, uniqueSize: 40)
        let b = DockerImage(id: "sha256:x", repository: "vexa/vexa-bot", tag: "b", size: 100, uniqueSize: 40)
        let r = VexaStorageReport(usage: DockerDiskUsage(images: [a, b], volumes: [], buildCache: 0),
                                  containers: [], referenced: [])
        XCTAssertEqual(r.size(of: r.images), 100)
        XCTAssertEqual(r.estimate(for: r.images), ReclaimEstimate(atLeast: 40, atMost: 100))
    }
}
