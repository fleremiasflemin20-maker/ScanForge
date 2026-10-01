import Foundation

if #available(macOS 14.0, *) {
    await ScanForgeReconstruct.main()
} else {
    FileHandle.standardError.write("mac-reconstruct requiere macOS 14 o superior (Object Capture / PhotogrammetrySession).\n".data(using: .utf8)!)
    exit(1)
}
