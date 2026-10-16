import Testing
import Foundation
@testable import ChatCore

@Test func jsonlAcrossUTF8ChunksAndEOF() throws {
 var reader = JSONLFramer()
 let bytes=Data("{\"text\":\"🌙\"}\n{\"type\":\"done\"}\n".utf8)
 var lines=[String]()
 for byte in bytes { lines += try reader.push(Data([byte])) }
 #expect(lines == ["{\"text\":\"🌙\"}","{\"type\":\"done\"}"])
 _ = try reader.push(Data("partial".utf8))
 #expect(throws: JSONLFramer.FramingError.self) { try reader.finish() }
}

@Test func centralLinkValidation() {
 #expect(LinkPolicy.url("https://example.com/path?q=one") != nil)
 #expect(LinkPolicy.url("HTTP://example.com") != nil)
 for raw in ["file:///etc/passwd","javascript:alert(1)","https://", "https://user:password@example.com", "https://example.com\nfoo","//example.com"] { #expect(LinkPolicy.url(raw) == nil) }
}

@Test func sessionGatesSendNewChatAndModelAndIgnoresLateOutput() throws {
 var session=ChatSession()
 let offlineSend=session.beginSend("hi"); #expect(offlineSend == nil)
 let ready=try JSONDecoder().decode(BridgeEvent.self,from:Data("{\"type\":\"ready\",\"messages\":[],\"model\":\"gpt-6-luna\",\"models\":[{\"model\":\"gpt-6-luna\",\"displayName\":\"Luna\"}]}".utf8))
 session.receive(ready)
 let first=session.beginSend(" hi \n"); #expect(first == "hi")
 let duplicate=session.beginSend("duplicate"); #expect(duplicate == nil)
 let busyNew=session.beginNewChat(), busyModel=session.beginModelChange("gpt-6-luna"); #expect(!busyNew); #expect(!busyModel)
 session.receive(BridgeEvent(type:"activeModel",model:"gpt-6-sol"))
 #expect(session.activeModel == "gpt-6-sol"); #expect(session.selectedModel == "gpt-6-luna")
 session.receive(BridgeEvent(type:"delta",itemId:"a",delta:"Hello"))
 session.receive(BridgeEvent(type:"message",itemId:"a",text:"Hello!"))
 #expect(session.messages.last?.text == "Hello!")
 session.receive(BridgeEvent(type:"done")); #expect(session.canInteract)
 session.receive(BridgeEvent(type:"delta",itemId:"late",delta:"ignored"))
 #expect(session.messages.count == 2)
 let fresh=session.beginNewChat(), blocked=session.beginSend("blocked"); #expect(fresh); #expect(blocked == nil)
}

@Test func commandWClosesPanelWithoutStoppingResponse() {
 #expect(KeyboardPolicy.action(code:13,modifiers:[.command]) == .dismiss)
 #expect(KeyboardPolicy.action(code:13,modifiers:[.command],streaming:true) == .dismiss)
 #expect(KeyboardPolicy.action(code:13,modifiers:[]) == .normal)
 #expect(KeyboardPolicy.action(code:13,modifiers:[.control]) == .normal)
}

@Test func keyboardSendNewlineEscapeAndPages() {
 #expect(KeyboardPolicy.action(code:36,modifiers:[]) == .send)
 #expect(KeyboardPolicy.action(code:36,modifiers:[.shift]) == .newline)
 #expect(KeyboardPolicy.action(code:53,modifiers:[],streaming:true) == .stop)
 #expect(KeyboardPolicy.action(code:53,modifiers:[]) == .dismiss)
 #expect(KeyboardPolicy.action(code:45,modifiers:[.command]) == .newChat)
 #expect(KeyboardPolicy.action(code:45,modifiers:[.control]) == .newChat)
 #expect(KeyboardPolicy.action(code:116,modifiers:[]) == .pageUp)
 #expect(KeyboardPolicy.action(code:121,modifiers:[]) == .pageDown)
 #expect(KeyboardPolicy.action(code:8,modifiers:[.command]) == .normal)
}

@Test func executableDiscoveryAndEnvironment() throws {
 let home="/home/test"
 let found=try RuntimeDiscovery.find(name:"node",override:"",home:home,path:"/bin",hermesEntries:["node-26.7.0-darwin-arm64"],exists:{$0 == "/home/test/.hermes/tools/node-26.7.0-darwin-arm64/bin/node"})
 #expect(found.hasSuffix("bin/node"))
 #expect(throws: RuntimeDiscovery.DiscoveryError.self) { try RuntimeDiscovery.find(name:"codex",override:"/invalid",home:home,path:"/bin",exists:{$0 == "/bin/codex"}) }
 let env=RuntimeDiscovery.environment(["OPENAI_API_KEY":"secret","NODE_OPTIONS":"bad","PATH":"/my/bin","HOME":home,"SPEEDCHAT_STATE_DIR":"/tmp/test"],home:home)
 #expect(env["OPENAI_API_KEY"] == nil); #expect(env["NODE_OPTIONS"] == nil)
 #expect(env["SPEEDCHAT_STATE_DIR"] == "/tmp/test")
 #expect(env["PATH"]!.contains("/opt/homebrew/bin")); #expect(env["PATH"]!.contains("/home/test/.local/bin"))
}

@Test func runtimeDirectoryIsPrivateEmptyAndUnique() throws {
 let a = try RuntimeDiscovery.createRuntimeDirectory()
 let b = try RuntimeDiscovery.createRuntimeDirectory()
 defer {
  try? FileManager.default.removeItem(at: a)
  try? FileManager.default.removeItem(at: b)
 }
 #expect(a != b)
 let items = try FileManager.default.contentsOfDirectory(atPath: a.path)
 #expect(items.isEmpty)
 let attrs = try FileManager.default.attributesOfItem(atPath: a.path)
 let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
 #expect((perms & 0o777) == 0o700)
 #expect(!RuntimeDiscovery.isExecutableFile(a.path))
}

@Test func fencedCodePartsIncludeUnfinishedStreamingBlock() {
 let parts=MarkdownBlocks.parse("Hello **world**\n```swift\nlet x = 1\n```\nAfter\n```math\nx²")
 #expect(parts.count == 4); #expect(parts[1].code); #expect(parts[1].language == "swift"); #expect(parts[1].text == "let x = 1")
 #expect(parts[3].code); #expect(parts[3].text == "x²")
}

@Test func proseBlocksGroupNonHeadingLinesForContiguousSelection() {
 let blocks=ProseBlocks.parse("# Overview\nFirst line\n- Bullet one\n> Quote\n## Next\nFinal line")
 #expect(blocks == [
  .init(text:"Overview",heading:true),
  .init(text:"First line\n•  Bullet one\n│  Quote",heading:false),
  .init(text:"Next",heading:true),
  .init(text:"Final line",heading:false),
 ])
}

@Test func errorsDoNotEnableOfflineOrBusySession() throws {
 var session=ChatSession()
 session.receive(BridgeEvent(type:"fatal",message:"Disconnected"))
 session.receive(BridgeEvent(type:"error",message:"late error"))
 #expect(!session.canInteract)
 session.connecting(); session.receive(BridgeEvent(type:"error",message:"startup failed")); #expect(!session.canInteract)
 let data=Data("{\"type\":\"ready\",\"model\":\"gpt-6-luna\"}".utf8)
 session.receive(try JSONDecoder().decode(BridgeEvent.self,from:data));_ = session.beginSend("Hello")
 session.receive(BridgeEvent(type:"error",message:"Blocked",busy:true)); #expect(session.streaming); #expect(!session.canInteract)
 #expect(!session.shouldStopIdle(hidden:true,elapsed:600))
 session.receive(BridgeEvent(type:"done")); #expect(session.canInteract); #expect(session.notice == "Blocked"); #expect(session.shouldStopIdle(hidden:true,elapsed:301)); #expect(!session.shouldStopIdle(hidden:false,elapsed:600))
}

@Test func openRouterModelIdentificationAndCatalogHotReload() throws {
 var session=ChatSession()
 let ready=try JSONDecoder().decode(BridgeEvent.self,from:Data("{\"type\":\"ready\",\"messages\":[],\"model\":\"gpt-6-luna\",\"models\":[{\"model\":\"gpt-6-luna\",\"displayName\":\"GPT-6 Luna\",\"provider\":\"openai\"}]}".utf8))
 session.receive(ready)
 #expect(session.models.first?.isOpenRouter == false)
 let update=try JSONDecoder().decode(BridgeEvent.self,from:Data("{\"type\":\"modelsUpdated\",\"model\":\"deepseek/deepseek-v4.1-flash\",\"models\":[{\"model\":\"gpt-6-luna\",\"displayName\":\"GPT-6 Luna\",\"provider\":\"openai\"},{\"model\":\"deepseek/deepseek-v4.1-flash\",\"displayName\":\"DeepSeek V4.1 Flash\",\"provider\":\"openrouter\"}]}".utf8))
 session.receive(update)
 #expect(session.models.count == 2)
 #expect(session.models.last?.isOpenRouter == true)
 #expect(session.selectedModel == "deepseek/deepseek-v4.1-flash")
}
