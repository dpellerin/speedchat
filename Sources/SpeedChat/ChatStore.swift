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
 @Published var pendingDeleteEntry:HistoryEntry?
 var hasActiveHistoryQuery:Bool {!historyQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
 private var activeConversationDeletedInHistory=false
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
 var historyRetention:HistoryRetention = .defaultPolicy
 var stateURL:URL?
 var environment:[String:String]=ProcessInfo.processInfo.environment
 var now:@Sendable ()->Date=Date.init
 var fixtureMode=false
 var fixtureCommands=[[String:String]]()
 var fixtureStatusNotice=""
 var changed:(()->Void)?
 var onHistoryChanged:(()->Void)?
 var shouldFocusComposer:()->Bool={true}
 init(makeBridge:@escaping ()->any ChatBackend={BridgeProcess()}) {self.makeBridge=makeBridge}
 func show() {
  hiddenAt=nil;idleTimer?.invalidate();idleTimer=nil
  if bridge != nil {warmReopens += 1} else if !fixtureMode {connect()}
  if !showingHistory {focusToken += 1}
 }
 func hide() {
  showingHistory=false;historyQuery="";pendingDeleteEntry=nil
  resetDeletedActiveConversationIfNeeded()
  hiddenAt=Date();scheduleIdle()
 }
 private func resetDeletedActiveConversationIfNeeded() {
  guard activeConversationDeletedInHistory else {return}
  activeConversationDeletedInHistory=false
  draft="";blankDraft="";followBottom=true
  if session.conversationId != nil || !session.messages.isEmpty {
   let event=session.phase == .offline
    ? BridgeEvent(type:"offlineConversation",conversationId:nil,messages:[],models:[],model:session.selectedModel,notice:session.notice,clearedActiveConversation:true)
    : BridgeEvent(type:"ready",conversationId:nil,messages:[],models:session.models,model:session.selectedModel,notice:"New chat",clearedActiveConversation:true)
   session.receive(event);changed?()
  }
 }
 private func scheduleIdle() {
  idleTimer?.invalidate()
  idleTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in Task { @MainActor in
   guard let self,let hidden=self.hiddenAt else {return}
   if self.session.shouldStopIdle(hidden:true,elapsed:Date().timeIntervalSince(hidden)) {self.stop();self.session.offline("Resting · reopen to reconnect")}
  }}
 }
 func connect() {
  guard !quitting else {return}
  showingHistory=false;historyQuery="";pendingDeleteEntry=nil;activeConversationDeletedInHistory=false
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
  let options=ChatClientOptions(
   stateURL:stateURL,
   env:environment,
   now:now,
   historyRetention:historyRetention
  )
  backend.start(codexOverride:codexOverride,options:options) {event in
   continuation.yield(event)
  }
 }
 func receive(_ event:BridgeEvent) {
  if event.type == "history" {
   if let eventQuery=event.query,eventQuery != historyQuery {
    if event.clearedActiveConversation != nil {onHistoryChanged?()}
    return
   }
   historyEntries=event.history ?? []
   selectedHistoryIndex=historyEntries.isEmpty ? 0 : min(max(selectedHistoryIndex,0),historyEntries.count-1)
   if !hasActiveHistoryQuery && historyEntries.isEmpty && event.clearedActiveConversation == true {
    draftsByConversation.removeAll()
   }
   changed?()
   onHistoryChanged?()
   return
  }
  if event.type == "ready" || event.type == "offlineConversation" {
   if event.clearedActiveConversation == true {
    if let oldId=session.conversationId {draftsByConversation.removeValue(forKey:oldId)}
    draft="";blankDraft="";followBottom=true;activeConversationDeletedInHistory=false
   } else if event.conversationId == nil {
    activeConversationDeletedInHistory=false
   }
   if event.type == "ready" {
    if session.phase == .connecting {readyMs=Date().timeIntervalSince(startedAt)*1000}
   }
   if shouldFocusComposer() && !showingHistory {focusToken += 1}
  }
  session.receive(event);changed?()
  if event.type == "done" {
   onHistoryChanged?()
   if shouldFocusComposer() && !showingHistory {focusToken += 1}
  } else if event.type == "ready" || event.type == "offlineConversation" || event.type == "conversationUpdated" {
   onHistoryChanged?()
  }
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
  blankDraft="";draft="";showingHistory=false;historyQuery="";pendingDeleteEntry=nil;activeConversationDeletedInHistory=false;followBottom=true;command(["type":"newChat"])
 }
 func openHistory() {
  guard session.canOpenHistory else {return}
  showingHistory=true
  historyQuery=""
  pendingDeleteEntry=nil
  activeConversationDeletedInHistory=false
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
  pendingDeleteEntry=nil
  resetDeletedActiveConversationIfNeeded()
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
  pendingDeleteEntry=nil
  activeConversationDeletedInHistory=false
  followBottom=(scrollToMessageId == nil)
  var cmd=["type":"openConversation","conversationId":id]
  if let scrollToMessageId,!scrollToMessageId.isEmpty {
   cmd["scrollToMessageId"]=scrollToMessageId
  }
  command(cmd)
 }
 @discardableResult
 func requestDeleteSelectedHistoryConversation() -> Bool {
  guard showingHistory,session.canOpenHistory,pendingDeleteEntry == nil,
        historyEntries.indices.contains(selectedHistoryIndex) else {return false}
  pendingDeleteEntry=historyEntries[selectedHistoryIndex]
  return true
 }
 func requestDeleteHistoryConversation(_ entry:HistoryEntry) {
  guard showingHistory,session.canOpenHistory else {return}
  pendingDeleteEntry=entry
 }
 func cancelDeleteHistoryConversation() {
  guard pendingDeleteEntry != nil else {return}
  pendingDeleteEntry=nil
  if showingHistory {historyFocusToken += 1}
 }
 func confirmDeleteHistoryConversation() {
  guard let entry=pendingDeleteEntry else {return}
  pendingDeleteEntry=nil
  guard session.canOpenHistory else {return}
  draftsByConversation.removeValue(forKey:entry.id)
  let deletingActive=entry.id == session.conversationId
  if deletingActive {
   draft="";blankDraft="";activeConversationDeletedInHistory=true
  }
  if bridge != nil || fixtureMode {
   var cmd=["type":"deleteConversation","conversationId":entry.id]
   if !historyQuery.isEmpty {cmd["query"]=historyQuery}
   command(cmd)
  } else if let deleted=try? StateStore.deleteConversation(id:entry.id,now:now(),stateURL:stateURL,env:environment) {
   let remaining=ConversationHistory.search(StateStore.loadConversations(stateURL:stateURL,env:environment),query:historyQuery)
   let activeRemoved=deletingActive || deleted.removedActive
   if activeRemoved {
    receive(BridgeEvent(type:"offlineConversation",conversationId:nil,messages:[],models:[],model:session.selectedModel,notice:session.notice,clearedActiveConversation:true))
   }
   receive(BridgeEvent(type:"history",history:remaining,clearedActiveConversation:activeRemoved,query:historyQuery))
  }
  if showingHistory {historyFocusToken += 1}
 }
 func countSavedHistory()->Int {
  if fixtureMode {return historyEntries.count}
  return StateStore.countSavedConversations(stateURL:stateURL,env:environment)
 }
 func countExpiredHistory(for policy:HistoryRetention)->Int {
  if fixtureMode {
   let current=now()
   return historyEntries.filter {policy.isExpired(updatedAt:$0.updatedAt,relativeTo:current)}.count
  }
  return StateStore.countExpiredConversations(retention:policy,now:now(),stateURL:stateURL,env:environment)
 }
 func applyHistoryRetention(_ policy:HistoryRetention) {
  historyRetention=policy
  if bridge != nil || fixtureMode {
   var cmd=["type":"applyRetention","retention":policy.rawValue]
   if !historyQuery.isEmpty {cmd["query"]=historyQuery}
   command(cmd)
  } else if let pruned=try? StateStore.pruneExpiredConversations(retention:policy,now:now(),stateURL:stateURL,env:environment) {
   for removedId in pruned.removedIds {draftsByConversation.removeValue(forKey:removedId)}
   let remaining=ConversationHistory.search(StateStore.loadConversations(stateURL:stateURL,env:environment),query:historyQuery)
   let activeRemoved=session.conversationId.map {pruned.removedIds.contains($0)} ?? false
   if activeRemoved {
    receive(BridgeEvent(type:"offlineConversation",conversationId:nil,messages:[],models:[],model:session.selectedModel,notice:session.notice,clearedActiveConversation:true))
   }
   receive(BridgeEvent(type:"history",history:remaining,clearedActiveConversation:activeRemoved,query:historyQuery))
  }
 }
 func clearAllHistory() {
  pendingDeleteEntry=nil
  activeConversationDeletedInHistory=false
  draftsByConversation.removeAll()
  if bridge != nil || fixtureMode {
   command(["type":"clearHistory"])
  } else if let cleared=try? StateStore.clearAllConversations(now:now(),stateURL:stateURL,env:environment) {
   let activeRemoved=session.conversationId != nil || !session.messages.isEmpty || cleared.removedActive
   if activeRemoved {
    receive(BridgeEvent(type:"offlineConversation",conversationId:nil,messages:[],models:[],model:session.selectedModel,notice:session.notice,clearedActiveConversation:true))
   }
   receive(BridgeEvent(type:"history",history:[],clearedActiveConversation:activeRemoved))
  }
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
