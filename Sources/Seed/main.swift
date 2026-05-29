// mcblink-seed — imports Blink cameras into the McBlink catalog.
// Reads the blink_helper.py `cameras` JSON and upserts a SiteProfile + one
// CameraProfile per camera via the real DatabaseManager (idempotent by name).
// Usage: mcblink-seed [path-to-cameras.json]   (default /tmp/blink_cameras.json)

import Foundation

struct HelperCam: Decodable {
    let name: String
    let id: String
    let network_id: Int
    let armed: Bool?
}
struct HelperResult: Decodable { let cameras: [HelperCam] }

let jsonPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/blink_cameras.json"

guard let data = FileManager.default.contents(atPath: jsonPath),
      let parsed = try? JSONDecoder().decode(HelperResult.self, from: data) else {
    FileHandle.standardError.write(Data("mcblink-seed: cannot read camera JSON at \(jsonPath)\n".utf8))
    exit(1)
}

let db = DatabaseManager()
let siteName = "Blink — Rock meadows"
let clipsBase = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("McBlink/clips", isDirectory: true).path

// Reuse existing IDs by name so re-running updates rather than duplicates.
let existingCams = (try? await db.fetchAllCameraProfiles()) ?? []
var nameToID = Dictionary(uniqueKeysWithValues: existingCams.map { ($0.name, $0.id) })

let camIDs: [UUID] = parsed.cameras.map { nameToID[$0.name] ?? UUID() }

let existingSites = (try? await db.fetchAllSiteProfiles()) ?? []
let siteID = existingSites.first(where: { $0.name == siteName })?.id ?? UUID()

try await db.upsertSiteProfile(SiteProfile(
    id: siteID, name: siteName, cameras: camIDs,
    storageBasePath: clipsBase, retentionDays: 7, offsiteEnabled: false
))
try? FileManager.default.createDirectory(atPath: clipsBase, withIntermediateDirectories: true)

for (cam, cid) in zip(parsed.cameras, camIDs) {
    let profile = CameraProfile(
        id: cid, name: cam.name, source: .blink,
        streamURL: "blink://\(cam.network_id)/\(cam.id)",
        substreamURL: nil, username: "dgillaspy@me.com", password: "",
        capabilities: [.motionEvents], detectionZones: [],
        isArmed: cam.armed ?? false, siteProfileID: siteID
    )
    try await db.upsertCameraProfile(profile)
    print("seeded camera: \(cam.name)  [blink \(cam.id)]  -> \(cid)")
}
print("done: \(parsed.cameras.count) cameras under site '\(siteName)'")
