import Foundation

/// Download progress can include source footage before its converted copy is
/// ready. The collection snapshot remains authoritative for folder creation.
struct DownloadFootageProgress {
    let availableMS: UInt64
    let remainingMS: UInt64
    let pendingConversionCount: Int

    init(collection: EngineSnapshot?, sources: EngineSnapshot?,
         conversionEnabled: Bool, targetMS: UInt64, retiredSources: Set<String> = []) {
        var available = collection?.available_ms ?? 0
        var pending = 0
        if conversionEnabled {
            let convertedNames = Set(collection?.clips.map(\.filename) ?? [])
            for source in sources?.clips ?? [] {
                let ext = URL(fileURLWithPath: source.filename).pathExtension.lowercased()
                guard ["mpg", "mpeg", "m2v"].contains(ext), source.duration_ms > 0,
                      !retiredSources.contains(source.filename),
                      !convertedNames.contains(source.filename + ".ProResLT.mov") else { continue }
                let (sum, overflow) = available.addingReportingOverflow(source.duration_ms)
                available = overflow ? UInt64.max : sum
                pending += 1
            }
        }
        availableMS = available
        remainingMS = targetMS - min(available, targetMS)
        pendingConversionCount = pending
    }
}
