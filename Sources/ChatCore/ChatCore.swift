import Foundation

public struct JSONLFramer: Sendable {
 private var buffer=Data()
 public init() {}
 public mutating func push(_ chunk: Data) throws -> [String] {
  buffer.append(chunk)
  guard buffer.count <= 8 * 1024 * 1024 else { throw FramingError.oversized }
  var lines=[String]()
  while let end=buffer.firstIndex(of:10) {
   let line=buffer[..<end]; buffer.removeSubrange(...end)
   guard let text=String(data:line,encoding:.utf8) else { throw FramingError.invalidUTF8 }
   if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { lines.append(text) }
  }
  return lines
 }
 public mutating func finish() throws { if !buffer.isEmpty { throw FramingError.truncated } }
 public enum FramingError: Error { case invalidUTF8, truncated, oversized }
}

public enum LinkPolicy {
 public static func url(_ raw: String) -> URL? {
  guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
    let parts=URLComponents(string:raw), let scheme=parts.scheme?.lowercased(), ["http","https"].contains(scheme),
    let host=parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
  return parts.url
 }
}

public struct KeyModifiers: OptionSet, Sendable {
 public let rawValue: Int
 public init(rawValue:Int) {self.rawValue=rawValue}
 public static let shift=Self(rawValue:1), command=Self(rawValue:2), control=Self(rawValue:4), option=Self(rawValue:8)
}
public enum KeyboardPolicy {
 public enum Action: Equatable {case send,newline,newChat,stop,dismiss,pageUp,pageDown,normal}
 public static func action(code:UInt16,modifiers:KeyModifiers,streaming:Bool=false) -> Action {
  if code == 13 && modifiers == [.command] {return .dismiss}
  if code == 53 {return streaming ? .stop : .dismiss}
  if code == 45 && (modifiers.contains(.command) || modifiers.contains(.control)) {return .newChat}
  if code == 116 {return .pageUp}; if code == 121 {return .pageDown}
  if code == 36 || code == 76 {return modifiers.contains(.shift) ? .newline : .send}
  return .normal
 }
}
