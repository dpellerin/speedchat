import SwiftUI
import ChatCore

@MainActor final class ChatStore: ObservableObject {
 @Published var session=ChatSession()
 @Published var draft=""
 @Published var composerHeight:CGFloat=48
 @Published var focusToken=0
 @Published var followBottom=true
 @Published var developerMetrics=false
 @Published var readyMs:Double=0
 @Published var coldStarts=0
 @Published var warmReopens=0
 var bridge:BridgeProcess?
 var eventTask:Task<Void,Never>?
 var generation=0
 var hiddenAt:Date?
 var idleTimer:Timer?
 var startedAt=Date()
 var nodeOverride="",codexOverride=""
 var fixtureMode=false
 var fixtureCommands=[[String:String]]()
 var changed:(()->Void)?
 func show() {
  hiddenAt=nil;idleTimer?.invalidate();idleTimer=nil
  if bridge != nil {warmReopens += 1} else if !fixtureMode {connect()}
  focusToken += 1
 }
 func hide() {hiddenAt=Date();scheduleIdle()}
 private func scheduleIdle() {
  idleTimer?.invalidate()
  idleTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in Task { @MainActor in
   guard let self,let hidden=self.hiddenAt else {return}
   if self.session.shouldStopIdle(hidden:true,elapsed:Date().timeIntervalSince(hidden)) {self.stop();self.session.offline("Resting · reopen to reconnect")}
  }}
 }
 func connect() {
  stop();session.connecting();startedAt=Date();coldStarts += 1
  let current=generation
  let backend=BridgeProcess();bridge=backend
  let bundled=Bundle.main.resourceURL?.appendingPathComponent("backend/bridge.js").path
  let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("backend/dist/bridge.js").path
  let (events,continuation)=AsyncStream<BridgeEvent>.makeStream()
  eventTask=Task { @MainActor [weak self] in
   for await event in events {
    guard let self,!Task.isCancelled,self.generation == current else {return}
    if event.type == "ready" {if self.session.phase == .connecting {self.readyMs=Date().timeIntervalSince(self.startedAt)*1000};self.focusToken += 1}
    self.session.receive(event);self.changed?()
    if event.type == "done" {self.focusToken += 1}
   }
  }
  let path=RuntimeDiscovery.bridgePath(bundled:bundled,source:source,exists:FileManager.default.fileExists(atPath:))
  backend.start(bridge:path,nodeOverride:nodeOverride,codexOverride:codexOverride) {event in
   continuation.yield(event)
   if event.type == "fatal" {continuation.finish()}
  }
 }
 func stop(completion:(@Sendable ()->Void)?=nil) {
  generation += 1;eventTask?.cancel();eventTask=nil;idleTimer?.invalidate();idleTimer=nil
  let old=bridge;bridge=nil
  if let old {old.close(completion:completion)} else {completion?()}
 }
 func command(_ value:[String:String]) {if fixtureMode {fixtureCommands.append(value)} else {bridge?.send(value)}}
 func send() {
  guard let text=session.beginSend(draft) else {return}
  draft="";followBottom=true;command(["type":"send","text":text])
 }
 func newChat() {guard session.beginNewChat() else {return};followBottom=true;command(["type":"newChat"])}
 func selectModel(_ model:String) {guard session.beginModelChange(model) else {return};command(["type":"selectModel","model":model])}
 func reloadConfig() {
  if bridge != nil && session.phase != .offline {command(["type":"reloadConfig"])}
  else if !fixtureMode {connect()}
 }
 func interrupt() {guard session.streaming else {return};session.stopping();command(["type":"interrupt"])}
 func retry() {guard session.canInteract,!session.lastRequest.isEmpty else {return};draft=session.lastRequest;send()}
}
