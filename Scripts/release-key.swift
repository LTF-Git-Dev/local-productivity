// LP's release key: signs each release's update.json, so LP only installs updates the owner released.
//
//   swift Scripts/release-key.swift create        make the key (once); prints its public half for
//                                                 UpdateFeed.publicKeys
//   swift Scripts/release-key.swift public        print the public half again
//   swift Scripts/release-key.swift sign <file>   write <file>.sig (base64 Ed25519 signature)
//   swift Scripts/release-key.swift verify <file> check <file>.sig against the public half
//
// The private half lives only in the owner's login Keychain (item "LP release signing key", kept as
// base64 text so it can be copied from Keychain Access into a password manager as a backup). It is
// never printed or written to a file by this script. If it is
// lost, existing installs can't be updated by LP any more: people download the next version by
// hand, and that version lists the new key.

import CryptoKit
import Foundation
import Security

let service = "LP release signing key"
let account = "LTF-Git-Dev"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-key: \(message)\n".utf8))
    exit(1)
}

func query() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    var q = query()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        if status == errSecItemNotFound { return nil }
        fail("couldn't read the key from the Keychain (status \(status)).")
    }
    guard let text = String(data: data, encoding: .utf8), let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("the Keychain item isn't a valid key.") }
    return key
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: create | public | sign <file> | verify <file>") }

switch args[1] {
case "create":
    if loadKey() != nil { fail("a release key already exists; nothing changed.") }
    let key = Curve25519.Signing.PrivateKey()
    var add = query()
    add[kSecAttrLabel as String] = service
    add[kSecAttrDescription as String] = "LP: signs update.json of each release"
    add[kSecValueData as String] = Data(key.rawRepresentation.base64EncodedString().utf8)
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("couldn't save the key in the Keychain (status \(status)).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = loadKey() else { fail("there is no release key yet (run create).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 3 else { fail("usage: sign <file>") }
    guard let key = loadKey() else { fail("there is no release key yet (run create).") }
    let url = URL(fileURLWithPath: args[2])
    guard let data = try? Data(contentsOf: url) else { fail("can't read \(args[2]).") }
    guard let signature = try? key.signature(for: data) else { fail("signing failed.") }
    try! Data((signature.base64EncodedString() + "\n").utf8).write(to: url.appendingPathExtension("sig"))
case "verify":
    guard args.count == 3 else { fail("usage: verify <file>") }
    guard let key = loadKey() else { fail("there is no release key yet (run create).") }
    let url = URL(fileURLWithPath: args[2])
    guard let data = try? Data(contentsOf: url),
          let text = try? String(contentsOf: url.appendingPathExtension("sig"), encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("can't read the file or its .sig.") }
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("the signature does not match.") }
    print("signature ok")
default:
    fail("unknown command \(args[1])")
}
