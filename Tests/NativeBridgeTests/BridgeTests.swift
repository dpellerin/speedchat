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
private func visibleDate(_ value:String)->String {
 value.replacingOccurrences(of:"\u{202F}",with:" ").replacingOccurrences(of:"\u{00A0}",with:" ")
}
@Test func aboutInfoFormatsVersionBuildAndRealTimestamp() throws {
 let pacific=try #require(TimeZone(identifier:"America/Los_Angeles"))
 let eastern=try #require(TimeZone(identifier:"America/New_York"))
 let locale=Locale(identifier:"en_US")
 func shown(_ raw:String,_ zone:TimeZone)->String {
  visibleDate(AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:raw,timeZone:zone,locale:locale).buildDateLine)
 }
 let stamped=AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:"2026-11-16T03:34:00Z",timeZone:pacific,locale:locale)
 #expect(stamped.versionLine == "Version 1.1.5 (7)")
 #expect(stamped.copyright == nil)
 #expect(visibleDate(stamped.buildDateLine) == "Built Nov 15, 2026 at 7:34 PM PST")
 #expect(shown("2026-11-16T03:07:00Z",eastern) == "Built Nov 15, 2026 at 10:07 PM EST")
 #expect(shown("2026-07-16T02:34:00Z",pacific) == "Built Jul 15, 2026 at 7:34 PM PDT")
 #expect(AboutInfo.make(name:"SpeedChat",version:"1.1.5",build:"7",buildDate:"2026-11-16T03:07:00Z",copyright:"  Copyright © 2026 Dana Pellerin  ",timeZone:pacific,locale:locale).copyright == "Copyright © 2026 Dana Pellerin")
 #expect(AboutInfo.make(name:"SpeedChat",version:nil,build:nil,buildDate:nil,copyright:"   ").copyright == nil)
 #expect(shown("  2026-11-16T03:07:00-08:00 ",pacific) == "Built Nov 16, 2026 at 3:07 AM PST")
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
 let pacific=try #require(TimeZone(identifier:"America/Los_Angeles"))
 let info=AboutInfo.current(bundle:stamped,timeZone:pacific,locale:Locale(identifier:"en_US"))
 #expect(info.name == "SpeedChat")
 #expect(info.versionLine == "Version 9.9.9 (42)")
 #expect(visibleDate(info.buildDateLine) == "Built Jan 2, 2026 at 7:04 AM PST")
 #expect(info.copyright == "Copyright © 2026 Dana Pellerin")
 let development=try bundle("about-dev","""
 <?xml version="1.0" encoding="UTF-8"?>
 <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
 <plist version="1.0"><dict>
 <key>CFBundleName</key><string>SpeedChat Dev</string>
 </dict></plist>
 """)
 #expect(AboutInfo.current(bundle:development) == AboutInfo(name:"SpeedChat Dev",versionLine:"Development",buildDateLine:"Development build",copyright:nil))
}

@MainActor @Test func panelChecksCodexDeliveryAndResendsOneVisibleMessage() throws {
 let store=ChatStore()
 store.fixtureMode=true
 store.session.receive(BridgeEvent(type:"ready",model:"gpt-6-luna"))
 store.draft="When does it open?"
 store.send()
 let prompt=try #require(store.session.messages.first)
 let executionID=try #require(store.session.executionID)
 #expect(store.fixtureCommands.last == ["type":"send","text":prompt.text,"itemId":prompt.id,"executionID":executionID.uuidString])

 store.session.receive(BridgeEvent(type:"error",message:"turn/start timed out.",
                                  codexRetry:CodexRetry(userMessageId:prompt.id,action:.checkDelivery)))
 #expect(store.session.notice.contains("may already have received"))
 store.retry()
 let retryID=try #require(store.session.executionID)
 #expect(retryID != executionID)
 #expect(store.fixtureCommands.last == ["type":"retryCodex","itemId":prompt.id,"executionID":retryID.uuidString])
 #expect(store.session.messages == [prompt])

 store.session.receive(BridgeEvent(type:"conversationUpdated",messages:[prompt],
                                  codexRetry:CodexRetry(userMessageId:prompt.id,action:.resend),
                                  executionID:retryID))
 #expect(store.session.notice.contains("could duplicate"))
 store.resend()
 let resendID=try #require(store.session.executionID)
 #expect(resendID != executionID && resendID != retryID)
 #expect(store.fixtureCommands.last == ["type":"resendCodex","itemId":prompt.id,"executionID":resendID.uuidString])
 store.session.receive(BridgeEvent(type:"delta",itemId:"late-reply",delta:"Late reply",executionID:executionID))
 store.session.receive(BridgeEvent(type:"conversationUpdated",messages:[],executionID:retryID))
 store.session.receive(BridgeEvent(type:"done",executionID:executionID))
 #expect(store.session.messages == [prompt])
 #expect(store.session.streaming)
 store.interrupt()
 #expect(store.fixtureCommands.last == ["type":"interrupt","executionID":resendID.uuidString])

 store.session.receive(BridgeEvent(type:"error",message:"Codex reply failed after receipt.",executionID:resendID))
 let commands=store.fixtureCommands
 store.retry()
 #expect(store.fixtureCommands == commands)

 store.session.receive(BridgeEvent(type:"ready",model:"example/router"))
 store.draft="A router prompt"
 store.send()
 store.session.receive(BridgeEvent(type:"error",message:"OpenRouter request failed."))
 store.retry()
 #expect(store.fixtureCommands.suffix(2).allSatisfy { $0["type"] == "send" && $0["text"] == "A router prompt" })
 #expect(store.session.messages.map(\.text) == ["A router prompt","A router prompt"])
}

@Test func lazyCodexResumePublishesRecoveredHistoryDuringNormalSend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("fake-codex")
    let script = """
        #!/usr/bin/env python3
        import json, sys
        resumes = 0
        def emit(value):
            print(json.dumps(value), flush=True)
        for raw in sys.stdin:
            request = json.loads(raw)
            method = request.get("method")
            mid = request.get("id")
            if method == "initialize" or method == "thread/name/set":
                emit({"id": mid, "result": {}})
            elif method == "model/list":
                emit({"id": mid, "result": {"data": [{"model": "gpt-6-luna", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}})
            elif method == "thread/resume":
                resumes += 1
                if resumes == 1:
                    emit({"id": mid, "error": {"code": -32603, "message": "Temporarily unavailable"}})
                else:
                    emit({"id": mid, "result": {"thread": {"id": "trail", "name": "Trail info", "turns": [
                        {"id": "previous", "items": [
                            {"id": "recorded", "type": "userMessage", "clientId": "saved",
                             "content": [{"type": "text", "text": "Where should I hike?"}]},
                            {"id": "recovered", "type": "agentMessage", "text": "Try Eagle Trail."}
                        ]}
                    ]}}})
            elif method == "turn/start":
                emit({"id": mid, "result": {"turn": {"id": "next"}}})
                params = request["params"]
                emit({"method": "item/started", "params": {"threadId": "trail", "turnId": "next",
                    "item": {"id": "receipt", "type": "userMessage", "clientId": params["clientUserMessageId"],
                             "content": params["input"]}}})
                emit({"method": "item/completed", "params": {"threadId": "trail", "turnId": "next",
                    "item": {"id": "final", "type": "agentMessage", "text": "At noon."}}})
                emit({"method": "turn/completed", "params": {"threadId": "trail",
                    "turn": {"id": "next", "status": "completed"}}})
        """
    try script.write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    let stateURL = root.appendingPathComponent("state.json")
    let saved = ChatMessage(id: "saved", role: "user", text: "Where should I hike?")
    try StateStore.save(threadId: "trail", model: "gpt-6-luna", to: stateURL, messages: [saved])

    let bridge = BridgeProcess()
    let (events, eventSink) = AsyncStream<BridgeEvent>.makeStream()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        eventSink.finish()
    }
    defer { timeout.cancel() }
    bridge.start(codexOverride: codex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]
    )) { event in eventSink.yield(event) }

    var session = ChatSession()
    var optimistic: ChatMessage?
    for await event in events {
        session.receive(event)
        if event.type == "ready" {
            #expect(session.messages == [saved])
            let draft = session.beginSend("When does it open?")
            let text = try #require(draft)
            let prompt = try #require(session.messages.last)
            optimistic = prompt
            let executionID = try #require(session.executionID)
            bridge.send(["type": "send", "text": text, "itemId": prompt.id, "executionID": executionID.uuidString])
        }
        if event.type == "historyRecovered" {
            #expect(session.streaming)
            #expect(session.messages.last == optimistic)
        }
        if event.type == "done" || event.type == "fatal" { break }
    }
    await withCheckedContinuation { continuation in
        bridge.close { continuation.resume() }
    }
    #expect(session.messages.map(\.text) == ["Where should I hike?", "Try Eagle Trail.", "When does it open?", "At noon."])
    #expect(session.canSend)
}

@Test func savedConversationReachesPanelWhenCodexExitsDuringStartup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("fake-codex")
    try "#!/bin/sh\nexit 17\n".write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    let stateURL = root.appendingPathComponent("state.json")
    let saved = ChatMessage(id: "saved", role: "assistant", text: "Try Eagle Trail.")
    try StateStore.save(threadId: "trail", model: "gpt-6-luna", to: stateURL, messages: [saved])

    let bridge = BridgeProcess()
    let (events, sink) = AsyncStream<BridgeEvent>.makeStream()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        sink.finish()
    }
    defer { timeout.cancel() }
    bridge.start(codexOverride: codex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]
    )) { event in sink.yield(event) }
    var stream = events.makeAsyncIterator()
    let initial = await stream.next()
    await withCheckedContinuation { continuation in
        bridge.close { continuation.resume() }
    }
    #expect(initial?.type == "offlineConversation")
    #expect(initial?.messages == [saved])
    #expect(initial?.models == [])
}
