import Testing
import Foundation
import ChatCore
@testable import SpeedChat
private actor EventLog {
 var events=[BridgeEvent]()
 func add(_ event:BridgeEvent) {events.append(event)}
 func contains(_ type:String)->Bool {events.contains{$0.type == type}}
}
private func waitFor(_ log:EventLog,_ type:String) async throws {
 for _ in 0..<150 {if await log.contains(type) {return};try await Task.sleep(for:.milliseconds(20))}
 throw NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for \(type)"])
}
@Test func nativeBridgeClosesPromptlyAfterCooperativeChildExit() async throws {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("mac-native-test-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 defer {try? FileManager.default.removeItem(at:root)}
 let script=root.appendingPathComponent("bridge.mjs")
 try "process.stdout.write('{\"type\":\"ready\"}\\n');process.stdin.on('data',()=>process.exit(0));".write(to:script,atomically:true,encoding:.utf8)
 let log=EventLog(), bridge=BridgeProcess()
 bridge.start(bridge:script.path,nodeOverride:"",codexOverride:"/usr/bin/true") {event in Task {await log.add(event)}}
 try await waitFor(log,"ready")
 let start=Date()
 await withCheckedContinuation {continuation in bridge.close {continuation.resume()} }
 #expect(Date().timeIntervalSince(start)<1.0)
 #expect(!(await log.contains("fatal")))
}
@Test func nativeBridgeDecodesFragmentedUTF8AndPropagatesEOFOnce() async throws {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("mac-native-test-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 defer {try? FileManager.default.removeItem(at:root)}
 let script=root.appendingPathComponent("bridge.mjs")
 let source="""
 const bytes=Buffer.from(JSON.stringify({type:'ready'})+'\\n'+JSON.stringify({type:'message',itemId:'a',text:'🌙 Hello'})+'\\npartial');
 for(let i=0;i<bytes.length;i++)setTimeout(()=>{process.stdout.write(bytes.subarray(i,i+1));if(i===bytes.length-1)setTimeout(()=>process.exit(0),20)},i*2);
 """
 try source.write(to:script,atomically:true,encoding:.utf8)
 let log=EventLog(), bridge=BridgeProcess()
 bridge.start(bridge:script.path,nodeOverride:"",codexOverride:"/usr/bin/true") {event in Task {await log.add(event)}}
 try await waitFor(log,"fatal")
 let events=await log.events
 #expect(events.filter{$0.type=="fatal"}.count == 1)
 #expect(events.first{$0.type=="message"}?.text == "🌙 Hello")
 #expect(events.first?.type == "ready")
 await withCheckedContinuation {continuation in bridge.close {continuation.resume()} }
}
@Test func nativeDiscoveryAcceptsExecutableSymlinks() async throws {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("mac-native-symlink-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 defer {try? FileManager.default.removeItem(at:root)}
 let script=root.appendingPathComponent("bridge.mjs"), alias=root.appendingPathComponent("codex-link")
 try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:URL(fileURLWithPath:"/usr/bin/true"))
 try "process.stdout.write('{\"type\":\"ready\"}\\n');process.stdin.on('data',()=>process.exit(0));".write(to:script,atomically:true,encoding:.utf8)
 let log=EventLog(), bridge=BridgeProcess()
 bridge.start(bridge:script.path,nodeOverride:"",codexOverride:alias.path) {event in Task {await log.add(event)}}
 do {try await waitFor(log,"ready");#expect(!(await log.contains("fatal")))} catch {await withCheckedContinuation {c in bridge.close {c.resume()}};throw error}
 await withCheckedContinuation {c in bridge.close {c.resume()}}
}
@Test @MainActor func openRouterPreferencesPersistWithPrivatePermissionsAndManageModels() throws {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("mac-prefs-or-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 defer {try? FileManager.default.removeItem(at:root)}
 let configURL=root.appendingPathComponent("openrouter.json")
 let prefs=Preferences(configURL:configURL)
 #expect(prefs.openRouterModels.count == 7)
 #expect(prefs.openRouterModels.first?.model == "deepseek/deepseek-v4.1-flash")
 prefs.openRouterKey="  sk-or-v1-test  "
 prefs.newModelInput="meta/muse-spark-open | Muse Spark Open"
 prefs.addOpenRouterModel()
 #expect(prefs.openRouterModels.count == 8)
 #expect(prefs.openRouterKey == "sk-or-v1-test")
 let attrs=try FileManager.default.attributesOfItem(atPath:configURL.path)
 let perms=(attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
 #expect((perms & 0o777) == 0o600)
 let reloaded=Preferences(configURL:configURL)
 #expect(reloaded.openRouterKey == "sk-or-v1-test")
 #expect(reloaded.openRouterModels.contains{$0.model == "meta/muse-spark-open" && $0.displayName == "Muse Spark Open"})
 reloaded.removeOpenRouterModel("meta/muse-spark-open")
 #expect(!reloaded.openRouterModels.contains{$0.model == "meta/muse-spark-open"})
}
