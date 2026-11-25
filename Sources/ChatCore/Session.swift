import Foundation
public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
 public var id: String
 public var role: String
 public var text: String
 public var reasoning: String?
 public init(id:String, role:String,text:String,reasoning:String?=nil) {self.id=id;self.role=role;self.text=text;self.reasoning=reasoning}
}
public struct ChatModel: Codable, Identifiable, Equatable, Sendable {
 public var model: String
 public var displayName: String
 public var provider: String?
 public var id: String {model}
 public var isOpenRouter: Bool { provider == "openrouter" || model.contains("/") }
 public init(model:String, displayName:String, provider:String?=nil) {
  self.model=model;self.displayName=displayName;self.provider=provider
 }
}
public struct BridgeEvent: Codable, Sendable {
 public var type: String
 public var conversationId: String?
 public var messages: [ChatMessage]?
 public var models: [ChatModel]?
 public var model: String?
 public var itemId: String?
 public var delta: String?
 public var text: String?
 public var message: String?
    public var notice: String?
    public var name: String?
    public var durationMs: Double?
    public var busy: Bool?
    public var stateSaveError: String?
    public var codexRetry: CodexRetry?
    public var executionID: UUID?
    public var history: [HistoryEntry]?
    public var query: String?
    public var scrollToMessageId: String?
    public init(
        type: String,
        conversationId: String? = nil,
        messages: [ChatMessage]? = nil,
        models: [ChatModel]? = nil,
        model: String? = nil,
        itemId: String? = nil,
        delta: String? = nil,
        text: String? = nil,
        message: String? = nil,
        notice: String? = nil,
        name: String? = nil,
        durationMs: Double? = nil,
        busy: Bool? = nil,
        stateSaveError: String? = nil,
        codexRetry: CodexRetry? = nil,
        executionID: UUID? = nil,
        history: [HistoryEntry]? = nil,
        query: String? = nil,
        scrollToMessageId: String? = nil
    ) {
        self.type = type
        self.conversationId = conversationId
        self.messages = messages
        self.models = models
        self.model = model
        self.itemId = itemId
        self.delta = delta
        self.text = text
        self.message = message
        self.notice = notice
        self.name = name
        self.durationMs = durationMs
        self.busy = busy
        self.stateSaveError = stateSaveError
        self.codexRetry = codexRetry
        self.executionID = executionID
        self.history = history
        self.query = query
        self.scrollToMessageId = scrollToMessageId
    }
}
public struct ChatSession: Sendable {
 public enum Phase: Sendable { case offline,connecting,ready,sending,selecting,resetting,checkingDelivery }
 public private(set) var phase: Phase = .offline
 public private(set) var conversationId: String?
 public private(set) var messages=[ChatMessage]()
 public private(set) var transcriptID=UUID()
 public private(set) var scrollTargetMessageId: String?
 public private(set) var models=[ChatModel]()
 public private(set) var selectedModel=""
 public private(set) var activeModel=""
 public private(set) var notice="Connecting…"
 public private(set) var lastRequest=""
 private var lastRequestWasOpenRouter=false
 private var activeCodexPromptId:String?
 public private(set) var executionID: UUID?
 private var codexRetry:CodexRetry?
 private var failureDetails:String?
 public private(set) var failed=false
 public private(set) var metrics=[String:Double]()
 public var canInteract: Bool { phase == .ready }
 public var canOpenHistory: Bool { phase == .ready || phase == .offline }
 private var selectedOpenRouter:Bool {
  models.first(where:{$0.model == selectedModel})?.isOpenRouter ?? selectedModel.contains("/")
 }
 public var visibleCodexRetry:CodexRetry? {canInteract && !selectedOpenRouter ? codexRetry : nil}
 public var canSend:Bool {
  canInteract && (visibleCodexRetry == nil || visibleCodexRetry?.action == .retry)
 }
 public var canRetryOpenRouter:Bool {canInteract && failed && lastRequestWasOpenRouter && !lastRequest.isEmpty}
 public var errorDetails:String {failureDetails ?? notice}
 public var busy: Bool { [.sending,.selecting,.resetting,.checkingDelivery].contains(phase) }
 public var streaming: Bool { phase == .sending }
 public init() {}
 public mutating func connecting() {phase = .connecting;notice="Connecting…";failed=false;executionID=nil}
 public mutating func offline(_ reason:String) {phase = .offline;notice=reason;executionID=nil}
 public mutating func beginSend(_ source:String) -> String? {
  let text=source.trimmingCharacters(in:.whitespacesAndNewlines)
  guard canSend, !text.isEmpty else {return nil}
  let id=UUID().uuidString.lowercased()
  executionID=UUID()
  scrollTargetMessageId=nil
  phase = .sending;notice="Thinking…";lastRequest=text;failed=false;failureDetails=nil;activeModel=selectedModel
  lastRequestWasOpenRouter=selectedOpenRouter
  activeCodexPromptId=selectedOpenRouter ? nil : id
  messages.append(ChatMessage(id:id,role:"user",text:text));return text
 }
 public mutating func beginCodexRetry(resend:Bool) -> String? {
  guard let retry=visibleCodexRetry,resend == (retry.action == .resend) else {return nil}
  switch retry.action {
  case .retry: phase = .sending;notice="Thinking…"
  case .checkDelivery: phase = .checkingDelivery;notice="Checking Codex delivery…"
  case .recoverReply: phase = .checkingDelivery;notice="Recovering the Codex reply…"
  case .resend: phase = .sending;notice="Checking Codex delivery…"
  }
  failed=false;failureDetails=nil;activeModel=selectedModel
  activeCodexPromptId=retry.userMessageId
  lastRequestWasOpenRouter=false
  executionID=UUID()
  return retry.userMessageId
 }
 public mutating func beginNewChat() -> Bool {guard canInteract else {return false};scrollTargetMessageId=nil;phase = .resetting;notice="Starting a new chat…";return true}
 public mutating func beginModelChange(_ model:String) -> Bool {
  guard canInteract, models.contains(where:{$0.model == model}) else {return false}
  phase = .selecting;notice="Changing model…";return true
 }
 public mutating func stopping() {if streaming {notice="Stopping…"}}
 public func shouldStopIdle(hidden:Bool,elapsed:TimeInterval) -> Bool {hidden && !busy && elapsed >= 300}
 public mutating func receive(_ event:BridgeEvent) {
  guard event.executionID == nil || event.executionID == executionID else {return}
  switch event.type {
  case "ready","offlineConversation":
   transcriptID=UUID();scrollTargetMessageId=event.scrollToMessageId;conversationId=event.conversationId;messages=event.messages ?? [];models=event.models ?? [];selectedModel=event.model ?? "";activeModel=selectedModel
   let isOffline=event.type == "offlineConversation"
   phase = isOffline ? .offline : .ready
   notice=(isOffline ? event.notice : (event.stateSaveError ?? event.notice)) ?? "Ready"
   failed=isOffline || event.stateSaveError != nil;failureDetails=event.stateSaveError ?? (isOffline ? notice : nil)
   lastRequest="";lastRequestWasOpenRouter=false;activeCodexPromptId=nil;executionID=nil
   updateCodexRetry(event.codexRetry)
  case "historyRecovered":
   guard streaming,let promptId=activeCodexPromptId,var recovered=event.messages else {return}
   if !recovered.contains(where:{$0.id == promptId}),
      let optimistic=messages.first(where:{$0.id == promptId && $0.role == "user"}) {recovered.append(optimistic)}
   messages=recovered
  case "codexReplyResumed":
   guard (streaming || phase == .checkingDelivery),let promptId=activeCodexPromptId,promptId == event.itemId else {return}
   messages=event.messages ?? messages;phase = .sending;notice="Thinking…";codexRetry=nil
  case "conversationUpdated":
   guard streaming || phase == .checkingDelivery else {return}
   if let id=event.conversationId {conversationId=id}
   messages=event.messages ?? messages
   phase = .ready;notice=event.stateSaveError ?? event.notice ?? "Ready";activeCodexPromptId=nil;executionID=nil
   failed=event.stateSaveError != nil;failureDetails=event.stateSaveError
   updateCodexRetry(event.codexRetry)
  case "codexDeliveryUpdated":
   updateCodexRetry(event.codexRetry)
   if let warning=event.stateSaveError, visibleCodexRetry != nil {notice=warning;failureDetails=warning}
  case "modelsUpdated":
   models=event.models ?? models
   if let updated=event.model, !updated.isEmpty { selectedModel=updated; if !streaming { activeModel=updated } }
   updateCodexRetry(event.codexRetry)
  case "modelSelected":
   guard phase == .selecting else {return}
   selectedModel=event.model ?? selectedModel;activeModel=selectedModel;phase = .ready;notice="Ready"
   failed=failed && lastRequestWasOpenRouter && selectedOpenRouter;failureDetails=nil
   updateCodexRetry(event.codexRetry)
  case "activeModel":
   if streaming {
    activeModel=event.model ?? activeModel
    if notice == "Checking Codex delivery…" {notice="Thinking…"}
   }
  case "replyPlaceholderRemoved":
   guard streaming, let id=event.itemId else {return}
   messages.removeAll {$0.id == id && $0.role == "assistant"}
  case "delta","message":
   guard streaming else {return}
   let id=event.itemId ?? "assistant"
   if let i=messages.firstIndex(where:{$0.id==id}) {if event.type == "delta" {messages[i].text += event.delta ?? ""} else {messages[i].text=event.text ?? ""}}
   else {
    let reply=ChatMessage(id:id,role:"assistant",text:event.type == "delta" ? event.delta ?? "" : event.text ?? "")
    let anchor=activeCodexPromptId.flatMap {promptId in messages.firstIndex {$0.id == promptId && $0.role == "user"}}
    let nextUser=anchor.flatMap {messages[($0+1)...].firstIndex {$0.role == "user"}}
    messages.insert(reply,at:nextUser ?? messages.count)
   }
  case "searching": if streaming {notice="Searching the web…"}
  case "done":
   guard streaming else {return}
   if let id=event.conversationId {conversationId=id}
   phase = .ready;activeCodexPromptId=nil;executionID=nil;if !failed {notice=event.stateSaveError ?? "Ready"}
   updateCodexRetry(event.codexRetry)
  case "error":
   guard phase != .offline else {return}
   if let id=event.conversationId {conversationId=id}
   failed=true;notice=event.message ?? "Something went wrong.";failureDetails=notice
   phase = phase == .connecting ? .offline : (event.busy == true ? .sending : .ready)
   if !streaming {executionID=nil}
   updateCodexRetry(event.codexRetry)
  case "fatal": failed=true;offline(event.message ?? "The backend disconnected.")
  case "metric": if let name=event.name,let ms=event.durationMs {metrics[name]=ms}
  default: break
  }
 }
 private mutating func updateCodexRetry(_ retry:CodexRetry?) {
  codexRetry=retry
  guard let visible=visibleCodexRetry else {return}
  failed=true
  if let warning=visible.notice {notice=warning}
  else if failureDetails == nil {notice="Codex did not receive this message. Retry to send it."}
 }
}
