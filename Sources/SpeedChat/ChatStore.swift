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
 var bridge:(any ChatBackend)?
 private let makeBridge:()->any ChatBackend
 private var teardown:Task<Void,Never>?
 private var quitting=false
 var eventTask:Task<Void,Never>?
 var generation=0
 var hiddenAt:Date?
 var idleTimer:Timer?
 var startedAt=Date()
 var codexOverride=""
 var fixtureMode=false
 var fixtureCommands=[[String:String]]()
 var fixtureStatusNotice=""
 var changed:(()->Void)?
 var shouldFocusComposer:()->Bool={true}
 init(makeBridge:@escaping ()->any ChatBackend={BridgeProcess()}) {self.makeBridge=makeBridge}
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
  guard !quitting else {return}
  stop();session.connecting()
  guard let teardown else {startBridge();return}
  let current=generation
  Task { [weak self] in
   await teardown.value
   guard let self,self.generation == current else {return}
   self.teardown=nil
   self.startBridge()
  }
 }
 private func startBridge() {
  startedAt=Date();coldStarts += 1
  let current=generation
  let backend=makeBridge();bridge=backend
  let (events,continuation)=AsyncStream<BridgeEvent>.makeStream()
  eventTask=Task { @MainActor [weak self] in
   for await event in events {
    guard let self,!Task.isCancelled,self.generation == current else {return}
    if event.type == "ready" {if self.session.phase == .connecting {self.readyMs=Date().timeIntervalSince(self.startedAt)*1000};if self.shouldFocusComposer() {self.focusToken += 1}}
    self.session.receive(event);self.changed?()
    if event.type == "done",self.shouldFocusComposer() {self.focusToken += 1}
   }
  }
  backend.start(codexOverride:codexOverride,options:ChatClientOptions()) {event in
   continuation.yield(event)
   if event.type == "fatal" {continuation.finish()}
  }
 }
 func stop(completion:(()->Void)?=nil) {
  generation += 1;eventTask?.cancel();eventTask=nil;idleTimer?.invalidate();idleTimer=nil
  if let outgoing=bridge {
   bridge=nil
   let (closed,signal)=AsyncStream<Void>.makeStream()
   outgoing.close {signal.finish()}
   teardown=Task {for await _ in closed {}}
  }
  guard let completion else {return}
  if let teardown {Task {await teardown.value;completion()}}
  else {completion()}
 }
 func quit(completion:@escaping ()->Void) {
  quitting=true
  stop(completion:completion)
 }
 func command(_ value:[String:String]) {if fixtureMode {fixtureCommands.append(value)} else {bridge?.send(value)}}
 func send() {
  guard let text=session.beginSend(draft),let id=session.messages.last?.id,
        let executionID=session.executionID else {return}
  draft="";followBottom=true;command(["type":"send","text":text,"itemId":id,"executionID":executionID.uuidString])
 }
 func newChat() {guard session.beginNewChat() else {return};followBottom=true;command(["type":"newChat"])}
 func selectModel(_ model:String) {guard session.beginModelChange(model) else {return};command(["type":"selectModel","model":model])}
 func reloadConfig() {
  if bridge != nil && session.phase != .offline {command(["type":"reloadConfig"])}
  else if !fixtureMode {connect()}
 }
 func interrupt() {
  guard session.streaming else {return}
  session.stopping()
  var stop=["type":"interrupt"]
  stop["executionID"]=session.executionID?.uuidString
  command(stop)
 }
 func retry() {
  if let id=session.beginCodexRetry(resend:false),let executionID=session.executionID {
   command(["type":"retryCodex","itemId":id,"executionID":executionID.uuidString])
  } else if session.canRetryOpenRouter {
   draft=session.lastRequest;send()
  }
 }
 func resend() {
  guard let id=session.beginCodexRetry(resend:true),let executionID=session.executionID else {return}
  command(["type":"resendCodex","itemId":id,"executionID":executionID.uuidString])
 }
}
