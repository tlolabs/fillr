// Called only after a verified transcode; checks source identity again before Trash.
import Foundation
import Darwin
let arguments = CommandLine.arguments
if arguments.count != 7 { exit(2) }
let source = arguments[1]
var info = stat()
guard lstat(source, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      String(info.st_dev) == arguments[2],
      String(info.st_ino) == arguments[3],
      String(info.st_size) == arguments[4],
      String(Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)) == arguments[5],
      String(Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)) == arguments[6]
else { fputs("Source changed; not moved to Trash\n", stderr); exit(3) }
do {
    var destination: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: source), resultingItemURL: &destination)
    print(destination?.path ?? "Moved to Trash")
} catch {
    fputs("Trash failed: \(error)\n", stderr)
    exit(4)
}
