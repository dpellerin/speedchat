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
 @Published var showingHistory=false
 @Published var historyQuery=""
 @Published var historyEntries=[HistoryEntry]()
 @Published var selectedHistoryIndex=0
 @Published var historyFocusToken=0
 var hasActiveHistoryQuery:Bool {!historyQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
 private var draftsByConversation=[String:String]()
 private var blankDraft=""
 var bridge:(any ChatBackend)?
 private let makeBridge:()->any ChatBackend
 private var teardown:Task<Void,Never>?
 private var quitting=false
 var eventTask:Task<Void,Never>?
 private var eventContinuation:AsyncStream<BridgeEvent>.Continuation?
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
  if !showingHistory {focusToken += 1}
 }
 func hide() {showingHistory=false;historyQuery="";hiddenAt=Date();scheduleIdle()}
 private func scheduleIdle() {
  idleTimer?.invalidate()
  idleTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in Task { @MainActor in
   guard let self,let hidden=self.hiddenAt else {return}
   if self.session.shouldStopIdle(hidden:true,elapsed:Date().timeIntervalSince(hidden)) {self.stop();self.session.offline("Resting · reopen to reconnect")}
  }}
 }
 func connect() {
  guard !quitting else {return}
  showingHistory=false;historyQuery=""
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
  eventContinuation=continuation
  eventTask=Task { @MainActor [weak self] in
   for await event in events {
    guard let self,!Task.isCancelled,self.generation == current else {return}
    self.receive(event)
   }
  }
  backend.start(codexOverride:codexOverride,options:ChatClientOptions()) {event in
   continuation.yield(event)
  }
 }
 func receive(_ event:BridgeEvent) {
  if event.type == "history" {
   if let eventQuery=event.query,eventQuery != historyQuery {return}
   historyEntries=event.history ?? []
   selectedHistoryIndex=historyEntries.isEmpty ? 0 : min(max(selectedHistoryIndex,0),historyEntries.count-1)
   changed?()
   return
  }
  if event.type == "ready" {
   if session.phase == .connecting {readyMs=Date().timeIntervalSince(startedAt)*1000}
   if shouldFocusComposer() && !showingHistory {focusToken += 1}
  } else if event.type == "offlineConversation" {
   if shouldFocusComposer() && !showingHistory {focusToken += 1}
  }
  session.receive(event);changed?()
  if event.type == "done",shouldFocusComposer() && !showingHistory {focusToken += 1}
 }
 func stop(completion:(()->Void)?=nil) {
  generation += 1;eventContinuation?.finish();eventContinuation=nil;eventTask?.cancel();eventTask=nil;idleTimer?.invalidate();idleTimer=nil
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
 private func saveDraftForCurrentConversation() {
  if let id=session.conversationId {
   if draft.isEmpty {draftsByConversation.removeValue(forKey:id)}
   else {draftsByConversation[id]=draft}
  } else {
   blankDraft=draft
  }
 }
 func send() {
  guard let text=session.beginSend(draft),let id=session.messages.last?.id,
        let executionID=session.executionID else {return}
  if let cid=session.conversationId {draftsByConversation.removeValue(forKey:cid)} else {blankDraft=""}
  draft="";followBottom=true;command(["type":"send","text":text,"itemId":id,"executionID":executionID.uuidString])
 }
 func newChat() {
  guard session.beginNewChat() else {return}
  if let cid=session.conversationId {
   if draft.isEmpty {draftsByConversation.removeValue(forKey:cid)}
   else {draftsByConversation[cid]=draft}
  }
  blankDraft="";draft="";showingHistory=false;historyQuery="";followBottom=true;command(["type":"newChat"])
 }
 func openHistory() {
  guard session.canOpenHistory else {return}
  showingHistory=true
  historyQuery=""
  selectedHistoryIndex=0
  historyFocusToken += 1
  command(["type":"listHistory"])
 }
 func updateHistoryQuery(_ query:String) {
  guard showingHistory else {return}
  historyQuery=query
  selectedHistoryIndex=0
  if query.isEmpty {
   command(["type":"listHistory"])
  } else {
   command(["type":"listHistory","query":query])
  }
 }
 func clearHistoryQuery() {
  guard showingHistory else {return}
  updateHistoryQuery("")
  historyFocusToken += 1
 }
 func closeHistory() {
  guard showingHistory else {return}
  showingHistory=false
  historyQuery=""
  if shouldFocusComposer() {focusToken += 1}
 }
 func toggleHistory() {
  if showingHistory {closeHistory()} else {openHistory()}
 }
 func moveHistorySelection(_ delta:Int) {
  guard showingHistory,!historyEntries.isEmpty else {return}
  selectedHistoryIndex=min(max(selectedHistoryIndex+delta,0),historyEntries.count-1)
 }
 func openSelectedHistoryConversation() {
  guard showingHistory,historyEntries.indices.contains(selectedHistoryIndex) else {return}
  let entry=historyEntries[selectedHistoryIndex]
  openHistoryConversation(id:entry.id,scrollToMessageId:hasActiveHistoryQuery ? entry.firstMatchingMessageId : nil)
 }
 func openHistoryConversation(id:String,scrollToMessageId:String?=nil) {
  guard session.canOpenHistory else {return}
  if id != session.conversationId {
   saveDraftForCurrentConversation()
   draft=draftsByConversation[id] ?? ""
  }
  showingHistory=false
  historyQuery=""
  followBottom=(scrollToMessageId == nil)
  var cmd=["type":"openConversation","conversationId":id]
  if let scrollToMessageId,!scrollToMessageId.isEmpty {
   cmd["scrollToMessageId"]=scrollToMessageId
  }
  command(cmd)
 }
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
