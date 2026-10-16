import AppKit
import Foundation
import ChatCore

extension AppDelegate {
 func runUISmoke() {
  var checks=[[String:Any]]()
  func check(_ name:String,_ condition:Bool) {checks.append(["name":name,"passed":condition])}
  let fixture="""
  {"type":"ready","model":"gpt-6-luna","models":[{"model":"gpt-6-luna","displayName":"GPT-6 Luna"},{"model":"gpt-6-sol","displayName":"GPT-6 Sol"}],"messages":[{"id":"u","role":"user","text":"Show me a short example with a source and readable math."},{"id":"a","role":"assistant","text":"A **native** conversation, with *selectable prose*.\\n\\n- One useful point\\n- A second point\\n\\n[Example source](https://example.com)\\n\\n```swift\\nlet greeting = \\\"Hello, Mac\\\"\\nprint(greeting)\\n```\\n\\n```math\\nx² + y² = r²\\n```"}]}
  """
  do {
   func composerIn(_ view:NSView)->ComposerTextView? {
    if let text=view as? ComposerTextView {return text}
    return view.subviews.lazy.compactMap(composerIn).first
   }
   let coldComposer=panel.contentView.flatMap(composerIn)
   check("Opening focuses editable composer before backend ready",coldComposer != nil && panel.firstResponder === coldComposer && coldComposer?.isEditable == true)
   let ready=try JSONDecoder().decode(BridgeEvent.self,from:Data(fixture.utf8));store.session.receive(ready)
   panel.contentView?.layoutSubtreeIfNeeded();panel.displayIfNeeded()
   func findDrag(_ view:NSView)->HeaderDragView? {if let drag=view as? HeaderDragView {return drag};return view.subviews.lazy.compactMap(findDrag).first}
   check("Header stays compact",panel.contentView.flatMap(findDrag).map{$0.bounds.height <= 32} ?? false)
   func findProse(_ view:NSView)->[LinkCursorView] {
    var found=[LinkCursorView]()
    if let prose=view as? LinkCursorView {found.append(prose)}
    for sub in view.subviews {found += findProse(sub)}
    return found
   }
   let proseViews=panel.contentView.map(findProse) ?? []
   let linkCursorConfigured=proseViews.contains {prose in
    let storage=prose.storage
    let text=storage.string as NSString
    let range=text.range(of:"Example source")
    guard range.location != NSNotFound else {return false}
    let cursor=storage.attribute(.cursor,at:range.location,effectiveRange:nil) as? NSCursor
    let link=storage.attribute(.link,at:range.location,effectiveRange:nil) as? URL
    return cursor == NSCursor.pointingHand && link?.absoluteString == "https://example.com"
   }
   check("Links configure pointing-hand cursor and validated URL",linkCursorConfigured)
   check("Panel is visible, normal-level and resizable",panel.isVisible && panel.level == .normal && !panel.isFloatingPanel && panel.styleMask.contains(.resizable))
   check("Panel dismisses after losing focus", {
    windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:panel))
    let hidden = !panel.isVisible
    show()
    return hidden
   }())
   check("Panel joins Spaces and fullscreen",panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
   func findComposer(_ view:NSView)->ComposerTextView? {if let text=view as? ComposerTextView {return text};for child in view.subviews {if let found=findComposer(child) {return found}};return nil}
   if let view=panel.contentView.flatMap(findComposer) {
    check("Native composer can receive focus",panel.makeFirstResponder(view))
    store.draft="Line one";view.string="Line one";view.setSelectedRange(NSRange(location:8,length:0))
    func event(_ key:UInt16,_ flags:NSEvent.ModifierFlags,_ chars:String)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:key)!}
    view.keyDown(with:event(36,.shift,"\r"));check("Shift Enter inserts native newline",view.string.contains("\n"))
    view.keyDown(with:event(36,[],"\r"));check("Enter sends exactly one request",store.fixtureCommands.filter{$0["type"] == "send"}.count == 1)
    store.newChat();check("New chat blocked during streaming",!store.fixtureCommands.contains{$0["type"] == "newChat"})
    store.interrupt();check("Stop sends interrupt",store.fixtureCommands.last?["type"] == "interrupt")
    store.session.receive(BridgeEvent(type:"done"));store.newChat();check("New chat available after completion",store.fixtureCommands.last?["type"] == "newChat")
   } else {check("Native composer is mounted",false)}
   let savedClipboard=NSPasteboard.general.string(forType:.string)
   NativeActions.copy("SpeedChat smoke clipboard");check("Native clipboard copy",NSPasteboard.general.string(forType:.string) == "SpeedChat smoke clipboard")
   if let savedClipboard {NativeActions.copy(savedClipboard)}
   check("Unsafe URL is never opened",!NativeActions.open(URL(fileURLWithPath:"/tmp/blocked")))
   showSettings()
   func hasScrollView(_ view:NSView)->Bool {if view is NSScrollView {return true};return view.subviews.contains(where:hasScrollView)}
   if let settingsContent=settingsWindow?.contentView {
    settingsContent.layoutSubtreeIfNeeded()
    check("Settings window has no scroll bar and fits content",!hasScrollView(settingsContent) && abs(settingsContent.bounds.height - settingsContent.fittingSize.height) <= 2)
    let hasPasteMenu=NSApp.mainMenu?.items.compactMap{$0.submenu}.flatMap{$0.items}.contains{$0.keyEquivalent == "v" && $0.action == #selector(NSText.paste(_:))} ?? false
    check("Edit menu enables Command-V paste in Settings fields",hasPasteMenu)
   } else {check("Settings window has no scroll bar and fits content",false)}
   settingsWindow?.orderOut(nil)
   show()
   let warm=store.warmReopens;store.bridge=BridgeProcess();hide();show();check("Reopen reuses bridge",store.warmReopens == warm+1);store.stop()
   store.session.receive(ready);store.focusToken += 1
   Task { @MainActor in
    try? await Task.sleep(for:.milliseconds(400))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    checks.append(["name":"Layout changes preserve transcript following","passed":self.store.followBottom])
    let path=CommandLine.arguments.firstIndex(of:"--smoke-output").flatMap {i in i+1<CommandLine.arguments.count ? CommandLine.arguments[i+1] : nil} ?? "/tmp/speedchat-ui-smoke"
    try? FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
    if let view=self.panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/panel.png"))}
    if let settingsView=self.settingsWindow?.contentView,let bitmap=settingsView.bitmapImageRepForCachingDisplay(in:settingsView.bounds) {settingsView.cacheDisplay(in:settingsView.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/settings.png"))}
    let failures=checks.filter{($0["passed"] as? Bool) != true}.count
    let report:[String:Any]=["checks":checks,"passed":checks.count-failures,"failed":failures,"note":"Fixture UI harness. Does not verify physical hotkey, all Spaces, login-item changes, or live response rendering." ]
    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path+"/report.json"))}
    self.hotkey.remove();exit(failures == 0 ? 0 : 1)
   }
  } catch {FileHandle.standardError.write(Data("UI smoke fixture failed: \(error)\n".utf8));exit(1)}
 }
}
