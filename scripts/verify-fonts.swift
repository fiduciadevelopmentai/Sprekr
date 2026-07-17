import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Fonts", isDirectory: true)
let expected: [(file: String, postScriptName: String)] = [
    ("Onest-Regular.otf", "Onest-Regular"),
    ("Onest-Medium.otf", "Onest-Medium"),
    ("Onest-Bold.otf", "Onest-Bold"),
]

for item in expected {
    let url = root.appendingPathComponent(item.file)
    var registrationError: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
        let message = registrationError?.takeRetainedValue().localizedDescription ?? "unknown Core Text error"
        fatalError("Could not register \(item.file): \(message)")
    }
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    guard let descriptor = descriptors.first else {
        fatalError("Core Text found no font descriptor in \(item.file)")
    }
    let font = CTFontCreateWithFontDescriptor(descriptor, 13, nil)
    guard CTFontCopyFamilyName(font) as String == "Onest",
          CTFontCopyPostScriptName(font) as String == item.postScriptName else {
        fatalError("Unexpected Core Text names in \(item.file)")
    }
}

print("Verified Onest Regular, Medium, and Bold Core Text names.")
