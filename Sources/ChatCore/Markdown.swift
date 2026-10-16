import Foundation
public enum MarkdownBlocks {
 public struct Part: Identifiable, Equatable, Sendable {
  public var id:Int
  public var text:String
  public var language:String
  public var code:Bool
 }
 public static func parse(_ source:String) -> [Part] {
  var parts=[Part](), lines=[String](), inCode=false, language=""
  func append() {let text=lines.joined(separator:"\n").trimmingCharacters(in:.newlines);if !text.isEmpty || inCode {parts.append(Part(id:parts.count,text:text,language:language,code:inCode))};lines=[]}
  for line in source.components(separatedBy:"\n") {
   if line.trimmingCharacters(in:.whitespaces).hasPrefix("```") {
    append()
    if inCode {inCode=false;language=""} else {inCode=true;language=String(line.trimmingCharacters(in:.whitespaces).dropFirst(3)).trimmingCharacters(in:.whitespaces)}
   } else {lines.append(line)}
  }
  append();return parts
 }
}
public enum ProseBlocks {
 public struct Block: Equatable, Sendable {
  public var text:String
  public var heading:Bool
 }
 public static func parse(_ source:String) -> [Block] {
  var blocks=[Block](), lines=[String]()
  func flush() {if !lines.isEmpty {blocks.append(Block(text:lines.joined(separator:"\n"),heading:false));lines=[]}}
  for line in source.components(separatedBy:"\n") {
   let trimmed=line.trimmingCharacters(in:.whitespaces)
   if trimmed.hasPrefix("#") {
    flush()
    blocks.append(Block(text:String(trimmed.drop(while:{$0 == "#" || $0 == " "})),heading:true))
   } else {
    let display=trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ? "•  "+String(trimmed.dropFirst(2)) : (trimmed.hasPrefix("> ") ? "│  "+String(trimmed.dropFirst(2)) : line)
    lines.append(display)
   }
  }
  flush();return blocks
 }
}
