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
    public init(
        type: String,
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
        busy: Bool? = nil
    ) {
        self.type = type
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
    }
}
public struct ChatSession: Sendable {
 public enum Phase: Sendable { case offline,connecting,ready,sending,selecting,resetting }
 public private(set) var phase: Phase = .offline
 public private(set) var messages=[ChatMessage]()
 public private(set) var transcriptID=UUID()
 public private(set) var models=[ChatModel]()
 public private(set) var selectedModel=""
 public private(set) var activeModel=""
 public private(set) var notice="Connecting…"
 public private(set) var lastRequest=""
 public private(set) var failed=false
 public private(set) var metrics=[String:Double]()
 public var canInteract: Bool { phase == .ready }
 public var busy: Bool { [.sending,.selecting,.resetting].contains(phase) }
 public var streaming: Bool { phase == .sending }
 public init() {}
 public mutating func connecting() {phase = .connecting;notice="Connecting…";failed=false}
 public mutating func offline(_ reason:String) {phase = .offline;notice=reason}
 public mutating func beginSend(_ source:String) -> String? {
  let text=source.trimmingCharacters(in:.whitespacesAndNewlines)
  guard canInteract, !text.isEmpty else {return nil}
  phase = .sending;notice="Thinking…";lastRequest=text;failed=false;activeModel=selectedModel
  messages.append(ChatMessage(id:UUID().uuidString,role:"user",text:text));return text
 }
 public mutating func beginNewChat() -> Bool {guard canInteract else {return false};phase = .resetting;notice="Starting a new chat…";return true}
 public mutating func beginModelChange(_ model:String) -> Bool {
  guard canInteract, models.contains(where:{$0.model == model}) else {return false}
  phase = .selecting;notice="Changing model…";return true
 }
 public mutating func stopping() {if streaming {notice="Stopping…"}}
 public func shouldStopIdle(hidden:Bool,elapsed:TimeInterval) -> Bool {hidden && !busy && elapsed >= 300}
 public mutating func receive(_ event:BridgeEvent) {
  switch event.type {
  case "ready": transcriptID=UUID();messages=event.messages ?? [];models=event.models ?? [];selectedModel=event.model ?? "";activeModel=selectedModel;phase = .ready;notice=event.notice ?? "Ready";failed=false
  case "modelsUpdated":
   models=event.models ?? models
   if let updated=event.model, !updated.isEmpty { selectedModel=updated; if !streaming { activeModel=updated } }
  case "modelSelected": guard phase == .selecting else {return}; selectedModel=event.model ?? selectedModel;activeModel=selectedModel;phase = .ready;notice="Ready"
  case "activeModel": if streaming {activeModel=event.model ?? activeModel}
  case "delta","message":
   guard streaming else {return}
   let id=event.itemId ?? "assistant"
   if let i=messages.firstIndex(where:{$0.id==id}) {if event.type == "delta" {messages[i].text += event.delta ?? ""} else {messages[i].text=event.text ?? ""}}
   else {messages.append(ChatMessage(id:id,role:"assistant",text:event.type == "delta" ? event.delta ?? "" : event.text ?? ""))}
  case "searching": if streaming {notice="Searching the web…"}
  case "done": guard streaming else {return};phase = .ready;if !failed {notice="Ready"}
  case "error": guard phase != .offline else {return}; failed=true;notice=event.message ?? "Something went wrong.";phase = phase == .connecting ? .offline : (event.busy == true ? .sending : .ready)
  case "fatal": failed=true;offline(event.message ?? "The backend disconnected.")
  case "metric": if let name=event.name,let ms=event.durationMs {metrics[name]=ms}
  default: break
  }
 }
}
