import SwiftUI
import ServiceManagement
import ChatCore

@MainActor final class Preferences:ObservableObject {
 static let defaultOpenRouterModels:[ChatModel]=OpenRouterClient.defaultModels
 let defaults:UserDefaults
 let configURL:URL
 @Published var codexPath:String {didSet {defaults.set(codexPath,forKey:"codexPath")}}
 @Published var metrics:Bool {didSet {defaults.set(metrics,forKey:"metrics")}}
 @Published var hotkey:HotKeyBinding
 @Published var openRouterKey=""
 @Published var showOpenRouterKey=false
 @Published var openRouterModels:[ChatModel]=Preferences.defaultOpenRouterModels
 @Published var newModelInput=""
 @Published var openRouterStatus=""
 @Published var error=""
 @Published var loginEnabled=false
 @Published var loginStatus=""
 var updateHotkey:((HotKeyBinding)throws->Void)?
 var reconnect:(()->Void)?
 var reloadConfig:(()->Void)?
 init(defaults:UserDefaults = .standard,configURL:URL?=nil) {
  self.defaults=defaults
  self.configURL=configURL ?? OpenRouterClient.configURL()
  codexPath=defaults.string(forKey:"codexPath") ?? ""
  metrics=defaults.bool(forKey:"metrics")
  hotkey=(defaults.data(forKey:"hotkey").flatMap{try? JSONDecoder().decode(HotKeyBinding.self,from:$0)}) ?? .standard
  loadOpenRouter()
 }
 func loadOpenRouter() {
  let loaded=OpenRouterClient.loadConfig(from:configURL,env:[:])
  openRouterKey=loaded.key
  openRouterModels=loaded.models.isEmpty ? Self.defaultOpenRouterModels : loaded.models
  updateOpenRouterStatus(saved:false)
 }
 private func updateOpenRouterStatus(saved:Bool) {
  let trimmed=openRouterKey.trimmingCharacters(in:.whitespacesAndNewlines)
  if trimmed.isEmpty {
   openRouterStatus=saved ? "Saved · Add an API key to enable OpenRouter models in the header picker." : "Enter an OpenRouter API key to use open-weight models alongside OpenAI."
  } else {
   openRouterStatus=(saved ? "Saved · " : "")+"\(openRouterModels.count) OpenRouter model\(openRouterModels.count == 1 ? "" : "s") enabled in the header picker."
  }
 }
 func saveOpenRouter() {
  do {
   let trimmedKey=openRouterKey.trimmingCharacters(in:.whitespacesAndNewlines)
   openRouterKey=trimmedKey
   if openRouterModels.isEmpty {openRouterModels=Self.defaultOpenRouterModels}
   try OpenRouterClient.saveConfig(key:trimmedKey,models:openRouterModels,to:configURL)
   error=""
   updateOpenRouterStatus(saved:true)
   reloadConfig?()
  } catch {
   self.error="OpenRouter config: "+error.localizedDescription
  }
 }
 func pasteOpenRouterKey() {
  guard let raw=NSPasteboard.general.string(forType:.string)?.trimmingCharacters(in:.whitespacesAndNewlines), !raw.isEmpty else {
   error="Clipboard does not contain text to paste."
   return
  }
  openRouterKey=raw
  saveOpenRouter()
 }
 static func parseModelEntry(_ raw:String)->ChatModel? {
  let trimmed=raw.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !trimmed.isEmpty else {return nil}
  return OpenRouterClient.parseModels([trimmed]).first
 }
 func addOpenRouterModel() {
  guard let entry=Self.parseModelEntry(newModelInput) else {return}
  if let idx=openRouterModels.firstIndex(where:{$0.model == entry.model}) {
   openRouterModels[idx]=entry
  } else {
   openRouterModels.append(entry)
  }
  newModelInput=""
  saveOpenRouter()
 }
 func removeOpenRouterModel(_ model:String) {
  openRouterModels.removeAll{$0.model == model}
  if openRouterModels.isEmpty {openRouterModels=Self.defaultOpenRouterModels}
  saveOpenRouter()
 }
 func resetOpenRouterModels() {
  openRouterModels=Self.defaultOpenRouterModels
  saveOpenRouter()
 }
 func record(_ value:HotKeyBinding) {do {try updateHotkey?(value);hotkey=value;defaults.set(try JSONEncoder().encode(value),forKey:"hotkey");error=""} catch {self.error=error.localizedDescription}}
 func refreshLogin() {
  loginEnabled=SMAppService.mainApp.status == .enabled
  switch SMAppService.mainApp.status {
  case .requiresApproval:loginStatus="Approval is required in System Settings → General → Login Items."
  case .notFound:loginStatus="This bundle is not registered. Keep the app at a stable location before enabling."
  default:loginStatus=loginEnabled ? "Enabled for this app bundle." : "Off. SpeedChat does not start at login."
  }
 }
 func setLogin(_ enable:Bool) {
  do {if enable {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()};error=""}
  catch {self.error="Launch at login: "+error.localizedDescription}
  refreshLogin()
 }
}
struct SettingsView:View {
 @ObservedObject var preferences:Preferences
 var body:some View {
  VStack(alignment:.leading,spacing:14) {
   VStack(alignment:.leading,spacing:12) {
    HStack {
     Text("Global shortcut")
     Spacer()
     ShortcutRecorder(label:preferences.hotkey.label,recorded:preferences.record).frame(minWidth:110).fixedSize()
    }
    Text("Click the shortcut, then press a combination including ⌘, ⌥ or ⌃. Escape cancels.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    Divider()
    HStack {
     Text("Launch at login")
     Spacer()
     Toggle("",isOn:Binding(get:{preferences.loginEnabled},set:preferences.setLogin)).labelsHidden().toggleStyle(.switch)
    }
    Text(preferences.loginStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
   }
   .padding(16)
   .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.controlBackgroundColor)))
   .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.secondary.opacity(0.18),lineWidth:1))

   VStack(alignment:.leading,spacing:10) {
    HStack {
     Text("OpenRouter").font(.headline)
     Spacer()
     Circle().fill(preferences.openRouterKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.5) : Color.green).frame(width:7,height:7)
     Text(preferences.openRouterKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Not configured" : "Active").font(.caption).foregroundStyle(.secondary)
    }
    HStack(spacing:8) {
     Group {
      if preferences.showOpenRouterKey {
       TextField("OpenRouter API key (sk-or-v1-…)",text:$preferences.openRouterKey)
      } else {
       SecureField("OpenRouter API key (sk-or-v1-…)",text:$preferences.openRouterKey)
      }
     }
      .textFieldStyle(.roundedBorder)
      .onSubmit {preferences.saveOpenRouter()}
     Button {preferences.showOpenRouterKey.toggle()} label:{Image(systemName:preferences.showOpenRouterKey ? "eye.slash" : "eye")}
      .buttonStyle(.borderless)
      .help(preferences.showOpenRouterKey ? "Hide API key" : "Show API key")
     Button("Paste") {preferences.pasteOpenRouterKey()}
      .help("Paste API key from clipboard and save")
     Button("Save Key") {preferences.saveOpenRouter()}
    }
    Text(preferences.openRouterStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    Divider()
    HStack {
     Text("Open-source models").font(.subheadline.weight(.medium))
     Spacer()
     Button("Reset Defaults") {preferences.resetOpenRouterModels()}.controlSize(.small)
    }
    VStack(alignment:.leading,spacing:5) {
     ForEach(preferences.openRouterModels) {item in
      HStack(spacing:8) {
       Text(item.displayName).font(.callout.weight(.medium)).lineLimit(1)
       Text(item.model).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
       Spacer(minLength:4)
       Button {preferences.removeOpenRouterModel(item.model)} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}
        .buttonStyle(.plain)
        .help("Remove \(item.displayName)")
        .disabled(preferences.openRouterModels.count <= 1)
      }
      .padding(.horizontal,8)
      .padding(.vertical,4)
      .background(RoundedRectangle(cornerRadius:6).fill(Color.secondary.opacity(0.08)))
     }
    }
    HStack(spacing:8) {
     TextField("Add model (slug or slug | Display Name)",text:$preferences.newModelInput)
      .textFieldStyle(.roundedBorder)
      .onSubmit {preferences.addOpenRouterModel()}
     Button("Add") {preferences.addOpenRouterModel()}
      .disabled(preferences.newModelInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
   }
   .padding(16)
   .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.controlBackgroundColor)))
   .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.secondary.opacity(0.18),lineWidth:1))

   if !preferences.error.isEmpty {
    Text(preferences.error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
   }
  }
  .padding(20)
  .frame(width:460)
  .fixedSize(horizontal:false,vertical:true)
  .onAppear {preferences.refreshLogin();preferences.loadOpenRouter()}
 }
}
