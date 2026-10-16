import Foundation
public enum RuntimeDiscovery {
 public enum DiscoveryError: Error, LocalizedError { case missing(String)
  public var errorDescription: String? { if case .missing(let name)=self {return "\(name) executable was not found. Make sure Node.js 20+ and the Codex CLI are installed."};return nil }
 }
 public static func bridgePath(bundled:String?,source:String,exists:(String)->Bool)->String {
  if let bundled,exists(bundled) {return bundled};return source
 }
 public static func environment(_ source:[String:String],home:String) -> [String:String] {
  var result=[String:String]()
  for name in ["HOME","USER","LOGNAME","TMPDIR","LANG","LC_ALL","CODEX_HOME","SPEEDCHAT_STATE_DIR"] {result[name]=source[name]}
  result["HOME"]=home
  result["PATH"]=([source["PATH"] ?? "","/opt/homebrew/bin","/usr/local/bin",home+"/.local/bin",home+"/.volta/bin",home+"/.asdf/shims",home+"/.local/share/mise/shims",home+"/.fnm/current/bin",home+"/Library/pnpm","/usr/bin","/bin"]).joined(separator:":")
  return result
 }
 public static func find(name:String,override:String,home:String,path:String,hermesEntries:[String]=[],exists:(String)->Bool) throws -> String {
  let specified=override.trimmingCharacters(in:.whitespacesAndNewlines)
  if !specified.isEmpty {guard specified.hasPrefix("/"),exists(specified) else {throw DiscoveryError.missing(name)};return specified}
  var candidates=(environment(["PATH":path],home:home)["PATH"] ?? "").split(separator:":").map{String($0)+"/"+name}
  if name == "node" {candidates += hermesEntries.filter{$0.hasPrefix("node-") && $0.contains("-darwin-")}.sorted().reversed().map{home+"/.hermes/tools/"+$0+"/bin/node"}}
  if let found=candidates.first(where:exists) {return found};throw DiscoveryError.missing(name)
 }
}
