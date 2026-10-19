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
   func renderedLinkHoverMatches() -> Bool {
    guard let content=panel.contentView,
          let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else {return false}
    content.cacheDisplay(in:content.bounds,to:bitmap)
    let probes=findProse(content)
    var hits=0,misses=0
    // Use actual blue link pixels as an independent oracle, rather than testing
    // TextKit rectangles against themselves. Convert through the hosting view
    // so this also exercises flipped coordinates and transcript positioning.
    for y in 0..<bitmap.pixelsHigh {
     for x in 0..<bitmap.pixelsWide {
      guard let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
            color.blueComponent > color.redComponent+0.2,
            color.blueComponent > color.greenComponent+0.1 else {continue}
      let pixelY=(CGFloat(y)+0.5)*content.bounds.height/CGFloat(bitmap.pixelsHigh)
      let point=NSPoint(x:(CGFloat(x)+0.5)*content.bounds.width/CGFloat(bitmap.pixelsWide),y:content.isFlipped ? pixelY : content.bounds.height-pixelY)
      for prose in probes {
       let local=prose.convert(point,from:content)
       guard prose.bounds.contains(local) else {continue}
       if prose.linkURL(at:local)?.absoluteString == "https://example.com" {hits += 1} else {misses += 1}
      }
     }
    }
    return hits > 0 && misses == 0
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
    check("Link hover matches visible link glyphs after multiple paragraphs",renderedLinkHoverMatches())
    let path=CommandLine.arguments.firstIndex(of:"--smoke-output").flatMap {i in i+1<CommandLine.arguments.count ? CommandLine.arguments[i+1] : nil} ?? "/tmp/speedchat-ui-smoke"
    try? FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
    if let view=self.panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/panel.png"))}
    if let settingsView=self.settingsWindow?.contentView,let bitmap=settingsView.bitmapImageRepForCachingDisplay(in:settingsView.bounds) {settingsView.cacheDisplay(in:settingsView.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/settings.png"))}
    // Start at the narrow panel width used by the reported blank transcript.
    self.panel.setContentSize(NSSize(width:580,height:740))
    for reset in 0..<5 {
     let longHistory=(0..<8).map { index in
      ChatMessage(id:"old-\(reset)-\(index)",role:index.isMultiple(of:2) ? "user" : "assistant",text:String(repeating:"Earlier conversation text. ",count:15))
     }
     self.store.session.receive(BridgeEvent(type:"ready",messages:longHistory,model:"gpt-6.1-sol"))
     try? await Task.sleep(for:.milliseconds(150))
     self.scroll.page(100)
     try? await Task.sleep(for:.milliseconds(100))
     self.store.newChat()
     self.store.session.receive(BridgeEvent(type:"ready",messages:[],model:"gpt-6.1-sol"))
     try? await Task.sleep(for:.milliseconds(100))
     if reset.isMultiple(of:2) {self.hide()}
     self.store.draft="Hello in the new chat"
     self.store.send()
     self.store.session.receive(BridgeEvent(type:"message",itemId:"new-reply-\(reset)",text:"New chat response is visible."))
     self.store.session.receive(BridgeEvent(type:"done"))
     try? await Task.sleep(for:.milliseconds(150))
     self.show()
     try? await Task.sleep(for:.milliseconds(150))
     self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
     let newReplyViews=self.panel.contentView.map(findProse) ?? []
     check("New chat \(reset) renders reply after clearing a scrolled transcript",newReplyViews.contains {
      $0.storage.string == "New chat response is visible." && !$0.visibleRect.isEmpty
     })
     if let view=self.panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/new-chat-\(reset).png"))}
    }
    if CommandLine.arguments.contains("--new-chat-smoke") {
     let failures=checks.filter{($0["passed"] as? Bool) != true}.count
     let report:[String:Any]=["checks":checks,"passed":checks.count-failures,"failed":failures]
     if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path+"/report.json"))}
     exit(failures == 0 ? 0 : 1)
    }
    let linkFixtures=[
     ("single-line","Read the [example source](https://example.com) here."),
     ("wrapped","A **bold** introduction with *emphasis* and `inline code` before a link. "+String(repeating:"More prose before the source. ",count:6)+"[A long example source label that wraps across multiple lines and keeps every visible word clickable](https://example.com)"),
     ("heading","## A [heading source](https://example.com)\n\nPlain prose below the heading.")
    ]
    for width in [580.0,790.0] {
     self.panel.setContentSize(NSSize(width:width,height:740))
     for (name,text) in linkFixtures {
      self.store.session.receive(BridgeEvent(type:"ready",messages:[ChatMessage(id:"link-fixture",role:"assistant",text:text)]))
      try? await Task.sleep(for:.milliseconds(100))
      self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
      check("Link hover matches \(name) text at width \(Int(width))",renderedLinkHoverMatches())
     }
    }
    func accessibleElements(_ element:Any,depth:Int=0)->[any NSAccessibilityProtocol] {
     guard depth < 30,let node=element as? any NSAccessibilityProtocol else {return []}
     return [node]+(node.accessibilityChildren() ?? []).flatMap{accessibleElements($0,depth:depth+1)}
    }
    let errorNotice="OpenRouter request failed (HTTP 400). "+String(repeating:"The provider rejected a request parameter. ",count:12)+"Diagnostic end marker."
    self.store.session.receive(BridgeEvent(type:"error",message:errorNotice))
    self.show()
    try? await Task.sleep(for:.milliseconds(100))
    self.panel.contentView?.layoutSubtreeIfNeeded()
    if let content=self.panel.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/error-panel.png"))}
    let notice=self.panel.flatMap{accessibleElements($0).first{($0.accessibilityValue() as? String) == errorNotice}}
    if let notice {
     // SwiftUI's virtual buttons are absent from in-process AX children. Send
     // mouse events only to this fixture window, at the screenshot-verified
     // Details position (100 points from the right edge, beside Retry).
     let screen=NSPoint(x:self.panel.frame.maxX-100,y:notice.accessibilityFrame().midY)
     let point=self.panel.convertPoint(fromScreen:screen)
     for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
      if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0) {self.panel.sendEvent(event)}
     }
     try? await Task.sleep(for:.milliseconds(150))
    }
    let errorWindows=NSApp.windows.filter{$0 !== self.panel && $0.isVisible}
    check("Error details open without dismissing chat",self.panel.isVisible && !errorWindows.isEmpty)
    check("Error details include complete selectable provider message",errorWindows.flatMap{accessibleElements($0)}.contains{($0.accessibilityValue() as? String) == errorNotice})
    for window in errorWindows {
     if let content=window.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/error-details.png"))}
    }
    let failures=checks.filter{($0["passed"] as? Bool) != true}.count
    let report:[String:Any]=["checks":checks,"passed":checks.count-failures,"failed":failures,"note":"Fixture UI harness. Does not verify physical hotkey, all Spaces, login-item changes, or live response rendering." ]
    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path+"/report.json"))}
    self.hotkey.remove();exit(failures == 0 ? 0 : 1)
   }
  } catch {FileHandle.standardError.write(Data("UI smoke fixture failed: \(error)\n".utf8));exit(1)}
 }
}
