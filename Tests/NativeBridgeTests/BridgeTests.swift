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
@Test func codexRpcStopRejectsPendingRequestsPromptlyAndRefusesServerToolCalls() async throws {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-rpc-test-" + UUID().uuidString)
 try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(at: root) }

 let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = """
    #!/usr/bin/env python3
    import json, sys
    # Older Codex CLIs reject unknown --disable flags before initialization.
    if "--disable" in sys.argv and "browser_annotation_api" in sys.argv:
        sys.exit("Unknown feature flag: browser_annotation_api")
    for raw in sys.stdin:
        msg = json.loads(raw)
        if msg.get("method") == "initialize":
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
            print(json.dumps({"id": "blocked", "method": "item/tool/call", "params": {"tool": "shell"}}), flush=True)
        elif msg.get("id") == "blocked" and "error" in msg:
            print(json.dumps({"method": "refused", "params": {"code": msg["error"]["code"]}}), flush=True)
    """
 try script.write(to: fakeCodex, atomically: true, encoding: .utf8)
 try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

 let (refusedStream, refusedCont) = AsyncStream<Int>.makeStream()
 let rpc = JsonRpcProcess(codexOverride: fakeCodex.path)
 rpc.onNotification = { notif in
  if notif.method == "refused", let code = notif.params["code"] as? Int {
   refusedCont.yield(code)
  }
 }

 try await rpc.start(cwd: root)
 var refusedCode = 0
 for await code in refusedStream {
  refusedCode = code
  break
 }
 #expect(refusedCode == -32601)

 let pendingTask = Task<Void, Error> {
  _ = try await rpc.request(method: "never", params: [:], timeoutMs: 5000)
 }
 try await Task.sleep(for: .milliseconds(30))
 await rpc.stop()
 await #expect(throws: Error.self) {
  try await pendingTask.value
 }
}
@Test func nativeBridgeStartsAndClosesCleanlyWithSymlinkedCodex() async throws {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-native-bridge-" + UUID().uuidString)
 try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(at: root) }

 let realCodex = root.appendingPathComponent("real-codex")
 let aliasCodex = root.appendingPathComponent("codex-link")
    let script = """
    #!/usr/bin/env python3
    import json, sys
    # Older Codex CLIs reject unknown --disable flags before initialization.
    if "--disable" in sys.argv and "browser_annotation_api" in sys.argv:
        sys.exit("Unknown feature flag: browser_annotation_api")
    for raw in sys.stdin:
        msg = json.loads(raw)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            print(json.dumps({"id": mid, "result": {}}), flush=True)
        elif method == "model/list":
            print(json.dumps({"id": mid, "result": {"data": [{"id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "GPT-6 Luna", "hidden": False, "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}}), flush=True)
        elif method == "thread/start":
            print(json.dumps({"id": mid, "result": {"thread": {"id": "t-1"}, "model": "gpt-6-luna"}}), flush=True)
        elif method == "thread/name/set":
            print(json.dumps({"id": mid, "result": {}}), flush=True)
    """
 try script.write(to: realCodex, atomically: true, encoding: .utf8)
 try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: realCodex.path)
 try FileManager.default.createSymbolicLink(at: aliasCodex, withDestinationURL: realCodex)

 let log = EventLog()
 let bridge = BridgeProcess()
 let stateDir = root.appendingPathComponent("state")
 let options = ChatClientOptions(
  openRouterConfigURL: stateDir.appendingPathComponent("openrouter.json"),
  stateURL: stateDir.appendingPathComponent("state.json"),
  env: ["SPEEDCHAT_STATE_DIR": stateDir.path]
 )
 bridge.start(codexOverride: aliasCodex.path, options: options) { event in
  Task { await log.add(event) }
 }
 try await waitFor(log, "ready")
 let start = Date()
 await withCheckedContinuation { continuation in
  bridge.close { continuation.resume() }
 }
 #expect(Date().timeIntervalSince(start) < 1.5)
 #expect(!(await log.contains("fatal")))
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
@Test @MainActor func statusMenuKeepsShortcutsAndAddsAbout() {
 #expect(AppDelegate.statusMenuSpec.map(\.title) == ["Show SpeedChat","New Chat","Settings…","About SpeedChat","Quit SpeedChat"])
 #expect(AppDelegate.statusMenuSpec.map(\.key) == ["","n",",","","q"])
 #expect(AppDelegate.statusMenuSpec.map(\.action) == [#selector(AppDelegate.showFromMenu),#selector(AppDelegate.newChat),#selector(AppDelegate.showSettings),#selector(AppDelegate.showAbout),#selector(AppDelegate.quit)])
}
@Test func aboutInfoFormatsVersionBuildAndRealTimestamp() {
 let stamped=AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:"2026-11-16T03:07:00Z")
 #expect(stamped == AboutInfo(name:"SpeedChat",versionLine:"Version 1.1.5 (7)",buildDateLine:"Built Nov 16, 2026, 3:07 AM UTC",copyright:nil))
 #expect(AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:"2026-11-16T03:07:00Z",copyright:"  Copyright © 2026 Dana Pellerin  ").copyright == "Copyright © 2026 Dana Pellerin")
 #expect(AboutInfo.make(name:"SpeedChat",version:nil,build:nil,buildDate:nil,copyright:"   ").copyright == nil)
 let shifted=AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:"  2026-11-16T03:07:00-08:00 ")
 #expect(shifted.buildDateLine == "Built Nov 16, 2026, 11:07 AM UTC")
 let versionOnly=AboutInfo.make(name:"SpeedChat",version:"1.2.0",build:" ",buildDate:"")
 #expect(versionOnly.versionLine == "Version 1.2.0")
 #expect(versionOnly.buildDateLine == "Development build")
 let missing=AboutInfo.make(name:" ",version:nil,build:nil,buildDate:nil)
 #expect(missing == AboutInfo(name:"SpeedChat",versionLine:"Development",buildDateLine:"Development build",copyright:nil))
 let unreadable=AboutInfo.make(name:nil,version:"1.1.5",build:"7",buildDate:"yesterday")
 #expect(unreadable.versionLine == "Version 1.1.5 (7)")
 #expect(unreadable.buildDateLine == "Build date unavailable")
}
@Test func aboutInfoReadsInfoPlistAndOmitsMissingBuildDate() throws {
 var roots=[URL]()
 defer {for root in roots {try? FileManager.default.removeItem(at:root)}}
 func bundle(_ name:String,_ plist:String) throws -> Bundle {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(name+"-"+UUID().uuidString+".app")
  try FileManager.default.createDirectory(at:root.appendingPathComponent("Contents"),withIntermediateDirectories:true)
  roots.append(root)
  try plist.write(to:root.appendingPathComponent("Contents/Info.plist"),atomically:true,encoding:.utf8)
  return try #require(Bundle(url:root))
 }
 let stamped=try bundle("about-stamped","""
 <?xml version="1.0" encoding="UTF-8"?>
 <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
 <plist version="1.0"><dict>
 <key>CFBundleDisplayName</key><string>SpeedChat</string>
 <key>CFBundleName</key><string>Ignored</string>
 <key>CFBundleShortVersionString</key><string>9.9.9</string>
 <key>CFBundleVersion</key><string>42</string>
 <key>SpeedChatBuildDate</key><string>2026-01-02T15:04:00Z</string>
 <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Dana Pellerin</string>
 </dict></plist>
 """)
 #expect(AboutInfo.current(bundle:stamped) == AboutInfo(name:"SpeedChat",versionLine:"Version 9.9.9 (42)",buildDateLine:"Built Jan 2, 2026, 3:04 PM UTC",copyright:"Copyright © 2026 Dana Pellerin"))
 let development=try bundle("about-dev","""
 <?xml version="1.0" encoding="UTF-8"?>
 <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
 <plist version="1.0"><dict>
 <key>CFBundleName</key><string>SpeedChat Dev</string>
 </dict></plist>
 """)
 #expect(AboutInfo.current(bundle:development) == AboutInfo(name:"SpeedChat Dev",versionLine:"Development",buildDateLine:"Development build",copyright:nil))
}
