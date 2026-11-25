import AppKit
import Foundation
import ChatCore

extension AppDelegate {
 func runUISmoke() async {
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
   func findSearchBar(_ view:NSView)->HistorySearchBarNSView? {
    if let bar=view as? HistorySearchBarNSView {return bar}
    return view.subviews.lazy.compactMap(findSearchBar).first
   }
   func findSearchField(_ view:NSView)->HistorySearchTextField? {
    findSearchBar(view)?.field
   }
   func findDeleteButtons(_ view:NSView)->[HistoryDeleteNSButton] {
    var found=[HistoryDeleteNSButton]()
    if let button=view as? HistoryDeleteNSButton {found.append(button)}
    for sub in view.subviews {found += findDeleteButtons(sub)}
    return found
   }
   let coldComposer=panel.contentView.flatMap(composerIn)
   check("Opening focuses editable composer before backend ready",coldComposer != nil && panel.firstResponder === coldComposer && coldComposer?.isEditable == true)
   let ready=try JSONDecoder().decode(BridgeEvent.self,from:Data(fixture.utf8));store.session.receive(ready)
   // SwiftUI mounts the new transcript on a later main-actor turn. Inspecting
   // synchronously can see the previous empty tree on a cold CI launch.
   try await Task.sleep(for:.milliseconds(400))
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
   check("App stays in Accessory activation policy",NSApp.activationPolicy() == .accessory)
   check("Panel is visible, normal-level and resizable",panel.isVisible && panel.level == .normal && !panel.isFloatingPanel && panel.styleMask.contains(.resizable))
   check("Panel stays visible when app deactivates",!panel.hidesOnDeactivate)
   check("Panel uses single-Space, Mission Control, and fullscreen auxiliary behavior",panel.collectionBehavior.contains(.moveToActiveSpace) && panel.collectionBehavior.contains(.managed) && panel.collectionBehavior.contains(.fullScreenAuxiliary) && !panel.collectionBehavior.contains(.canJoinAllSpaces))
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
   check("Panel stays visible when another window receives focus",panel.isVisible && settingsWindow?.isKeyWindow == true)
   check("Settings window uses single-Space move-to-active-Space behavior",settingsWindow?.collectionBehavior.contains(.moveToActiveSpace) == true && settingsWindow?.collectionBehavior.contains(.canJoinAllSpaces) == false)
   func hasScrollView(_ view:NSView)->Bool {if view is NSScrollView {return true};return view.subviews.contains(where:hasScrollView)}
   func accessibleElements(_ element:Any,depth:Int=0)->[any NSAccessibilityProtocol] {
    guard depth < 30,let node=element as? any NSAccessibilityProtocol else {return []}
    return [node]+(node.accessibilityChildren() ?? []).flatMap{accessibleElements($0,depth:depth+1)}
   }
   if let settingsContent=settingsWindow?.contentView {
    settingsContent.layoutSubtreeIfNeeded()
    check("Settings window has no scroll bar and fits content",!hasScrollView(settingsContent) && abs(settingsContent.bounds.height - settingsContent.fittingSize.height) <= 2)
    let hasPasteMenu=NSApp.mainMenu?.items.compactMap{$0.submenu}.flatMap{$0.items}.contains{$0.keyEquivalent == "v" && $0.action == #selector(NSText.paste(_:))} ?? false
    check("Edit menu enables Command-V paste in Settings fields",hasPasteMenu)
   } else {check("Settings window has no scroll bar and fits content",false)}
   toggleFromHotKey()
   let raisedComposer=panel.contentView.flatMap(composerIn)
   check("Smart-toggle raises and focuses unfocused panel on current Space",panel.isVisible && panel.isKeyWindow && raisedComposer != nil && panel.firstResponder === raisedComposer)
   settingsWindow?.orderOut(nil)
   showAbout()
   check("About window uses single-Space move-to-active-Space behavior",aboutWindow?.collectionBehavior.contains(.moveToActiveSpace) == true && aboutWindow?.collectionBehavior.contains(.canJoinAllSpaces) == false)
   let about=AboutInfo.current()
   let bundleVersion=(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String) ?? ""
   let bundleBuild=(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String) ?? ""
   let stamped=(Bundle.main.object(forInfoDictionaryKey:"SpeedChatBuildDate") as? String) ?? ""
   let built=AboutInfo.parseBuildDate(stamped)
   let zone=built.flatMap{TimeZone.current.abbreviation(for:$0)} ?? ""
   let copyright=(Bundle.main.object(forInfoDictionaryKey:"NSHumanReadableCopyright") as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
   check("About window shows the bundled version, local build time, and copyright",aboutWindow?.isVisible == true && aboutWindow?.isKeyWindow == true && aboutWindow?.title == "About SpeedChat" && !bundleVersion.isEmpty && about.versionLine.contains(bundleVersion) && about.versionLine.contains("(\(bundleBuild))") && built != nil && about.buildDateLine.hasPrefix("Built ") && !zone.isEmpty && about.buildDateLine.contains(zone) && !copyright.isEmpty && about.copyright == copyright)
   aboutWindow?.orderOut(nil)
   show()
   try await Task.sleep(for:.milliseconds(100))
   showFromMenu()
   let keptOpenFromMenu=panel.isVisible && panel.isKeyWindow
   toggleFromHotKey()
   let hiddenBySmartToggle = !panel.isVisible
   toggleFromHotKey()
   let reopenedComposer=panel.contentView.flatMap(composerIn)
   let reopenedBySmartToggle=panel.isVisible && panel.isKeyWindow && reopenedComposer != nil && panel.firstResponder === reopenedComposer
   check("Menu bar Show keeps focused panel open and smart-toggle hides then reopens with composer focus",keptOpenFromMenu && hiddenBySmartToggle && reopenedBySmartToggle)
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
    let pending=ChatMessage(id:"delivery-prompt",role:"user",text:"When does the orchard open?")
    self.store.session.receive(BridgeEvent(type:"ready",messages:[pending],models:ready.models,model:"gpt-6-luna",
                                          codexRetry:CodexRetry(userMessageId:pending.id,action:.checkDelivery)))
    self.store.retry()
    let retryExecutionID=self.store.session.executionID
    let retryCommand=self.store.fixtureCommands.last
    check("Retry checks delivery of the original prompt",
          retryExecutionID != nil && retryCommand?["type"] == "retryCodex" &&
          retryCommand?["itemId"] == pending.id && retryCommand?["executionID"] == retryExecutionID?.uuidString &&
          self.store.session.messages == [pending])
    self.store.session.receive(BridgeEvent(type:"conversationUpdated",messages:[pending],
                                          codexRetry:CodexRetry(userMessageId:pending.id,action:.resend),
                                          executionID:retryExecutionID))
    let warning="Codex may already have received this message. Sending it again could duplicate it."
    for _ in 0..<30 {
     if self.store.fixtureStatusNotice == warning {break}
     try? await Task.sleep(for:.milliseconds(25))
    }
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    check("Panel displays the uncertainty warning before resend",
          self.panel.isVisible && self.store.fixtureStatusNotice == warning)
    self.store.resend()
    let resendExecutionID=self.store.session.executionID
    let resendCommand=self.store.fixtureCommands.last
    check("Explicit resend dispatches the original prompt and preserves one row",
          resendExecutionID != nil && resendExecutionID != retryExecutionID &&
          resendCommand?["type"] == "resendCodex" && resendCommand?["itemId"] == pending.id &&
          resendCommand?["executionID"] == resendExecutionID?.uuidString &&
          self.store.session.messages == [pending])
    self.store.session.receive(BridgeEvent(type:"done",executionID:resendExecutionID))

    let later=ChatMessage(id:"later-prompt",role:"user",text:"Are the trails open?")
    self.store.session.receive(BridgeEvent(type:"ready",messages:[pending,later],models:ready.models,model:"gpt-6-luna",
                                          codexRetry:CodexRetry(userMessageId:pending.id,action:.checkDelivery)))
    self.store.retry()
    self.store.session.receive(BridgeEvent(type:"codexReplyResumed",messages:[pending,later],itemId:pending.id))
    let commands=self.store.fixtureCommands.count
    self.store.draft="Another question"
    self.store.send()
    check("Panel gates Send while the original Codex reply streams",
          self.store.session.streaming && self.store.fixtureCommands.count == commands)
    let reply=ChatMessage(id:"live-reply",role:"assistant",text:"The orchard opens at noon.")
    self.store.session.receive(BridgeEvent(type:"delta",itemId:reply.id,delta:"The orchard"))
    self.store.session.receive(BridgeEvent(type:"message",itemId:reply.id,text:reply.text))
    self.store.session.receive(BridgeEvent(type:"done"))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    check("Panel renders the original Codex reply in its own turn",
          self.store.session.messages == [pending,reply,later] && self.store.session.canSend &&
          (self.panel.contentView.map(findProse) ?? []).contains {$0.storage.string == reply.text && !$0.visibleRect.isEmpty})

    let offlineNotice="Codex is offline. Reconnect to continue."
    self.store.session.receive(BridgeEvent(type:"offlineConversation",conversationId:"conv-offline-a",messages:[pending,reply],models:[],model:"gpt-6-luna",notice:offlineNotice))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    check("Panel shows the saved conversation while offline",
          self.store.session.phase == .offline && !self.store.session.canSend && self.store.fixtureStatusNotice == offlineNotice &&
          (self.panel.contentView.map(findProse) ?? []).contains {$0.storage.string == reply.text && !$0.visibleRect.isEmpty})

    // Conversation History smoke checks: status menu entry, offline browse/open,
    // online in-place UI with compact header, keyboard navigation, scroll-to-bottom,
    // per-conversation draft preservation, and Esc / hide abandon back to composer focus.
    check("Status menu includes History with Command-K shortcut",
          Self.statusMenuSpec.contains {$0.title == "History" && $0.key == "k" && $0.action == #selector(AppDelegate.showHistory)})

    let smokeNow=Date()
    let iso=ISO8601DateFormatter()
    iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    let historyA=HistoryEntry(id:"conv-offline-a",title:"Orchard opening hours",updatedAt:iso.string(from:smokeNow.addingTimeInterval(-120)),preview:"The orchard opens at noon.",model:"gpt-6-luna",messageCount:2)
    let historyB=HistoryEntry(id:"conv-older-b",title:"Lisbon weekend itinerary",updatedAt:iso.string(from:smokeNow.addingTimeInterval(-7200)),preview:"Start in Alfama and ride Tram 28.",model:"gpt-6-sol",messageCount:10)

    self.store.openHistory()
    self.store.receive(BridgeEvent(type:"history",history:[]))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let emptyHistoryRendered=self.panel.contentView.map{!hasScrollView($0) && composerIn($0) == nil} ?? false
    let searchFieldOnOpen=self.panel.contentView.flatMap(findSearchField)
    check("History search bar receives keyboard focus automatically when History opens",
          searchFieldOnOpen != nil && searchFieldOnOpen?.isFocusedInWindow == true)
    self.store.receive(BridgeEvent(type:"history",history:[historyA,historyB]))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let historyWindows=NSApp.windows.filter{$0 !== self.panel && $0.isVisible}
    let historyHeaderCompact=self.panel.contentView.flatMap(findDrag).map{$0.bounds.height <= 32} ?? false
    let populatedHistoryScrollable=self.panel.contentView.map{hasScrollView($0) && composerIn($0) == nil} ?? false
    check("History opens in-place inside Panel while offline with empty state and compact header",
          self.store.showingHistory && historyWindows.isEmpty && historyHeaderCompact && emptyHistoryRendered && populatedHistoryScrollable &&
          self.store.fixtureCommands.last?["type"] == "listHistory")
    if let content=self.panel.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/history.png"))}

    self.store.moveHistorySelection(1)
    self.store.openSelectedHistoryConversation()
    let offlineResumedMessages=(0..<14).map {idx in
     if idx == 1 {
      return ChatMessage(id:"lisbon-1",role:"assistant",text:"Ride Tram 28 through historic Alfama at sunrise.")
     }
     return ChatMessage(id:"lisbon-\(idx)",role:idx.isMultiple(of:2) ? "user" : "assistant",text:idx == 13 ? "Final Lisbon recommendation at bottom." : String(repeating:"Lisbon notes paragraph \(idx). ",count:14))
    }
    self.store.receive(BridgeEvent(type:"offlineConversation",conversationId:historyB.id,messages:offlineResumedMessages,models:[],model:"gpt-6-sol",notice:offlineNotice))
    try? await Task.sleep(for:.milliseconds(200))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    check("Selecting a saved conversation while offline opens it in read-only mode scrolled to bottom",
          !self.store.showingHistory && self.store.session.phase == .offline && self.store.session.conversationId == historyB.id &&
          self.store.fixtureCommands.last == ["type":"openConversation","conversationId":historyB.id] &&
          (self.panel.contentView.map(findProse) ?? []).contains {$0.storage.string == "Final Lisbon recommendation at bottom." && !$0.visibleRect.isEmpty})

    // Online ready mode: search bar no-match empty state, inline clear, Esc with query text,
    // and selecting a search match (including re-selecting the active conversation) scrolling to the matched message with Latest pill available.
    self.store.receive(BridgeEvent(type:"ready",conversationId:historyB.id,messages:offlineResumedMessages,models:ready.models,model:"gpt-6-sol"))
    self.store.draft="Unsent Lisbon note"
    self.store.openHistory()
    try? await Task.sleep(for:.milliseconds(150))
    let searchBarWhenEmpty=self.panel.contentView.flatMap(findSearchBar)
    let clearHiddenWhenEmpty=searchBarWhenEmpty?.clearButton.isHidden == true
    self.store.updateHistoryQuery("nonexistent xylophone")
    self.store.receive(BridgeEvent(type:"history",history:[],query:"nonexistent xylophone"))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let noMatchStateRendered=self.store.fixtureHistoryEmptyTitle == "No matching conversations"
    if let content=self.panel.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/history-no-matches.png"))}
    let noMatchNoScrollView=self.panel.contentView.map{!hasScrollView($0)} ?? false
    let searchBarWithQuery=self.panel.contentView.flatMap(findSearchBar)
    let clearVisibleWhenNonEmpty=searchBarWithQuery?.clearButton.isHidden == false
    searchBarWithQuery?.clearButton.performClick(nil)
    try? await Task.sleep(for:.milliseconds(100))
    let searchFieldAfterClear=self.panel.contentView.flatMap(findSearchField)
    check("History search shows No matching conversations empty state",
          noMatchStateRendered && noMatchNoScrollView)
    check("History search inline clear button appears when non-empty and clears while keeping focus",
          clearHiddenWhenEmpty && clearVisibleWhenNonEmpty &&
          self.store.historyQuery.isEmpty && searchBarWithQuery?.clearButton.isHidden == true &&
          searchFieldAfterClear?.isFocusedInWindow == true)

    // Press Esc while query text is in the search bar: closes History in one keypress, keeping draft & composer focus.
    self.store.updateHistoryQuery("alfama")
    let matchedLisbon=HistoryEntry(
     id:historyB.id,
     title:historyB.title,
     updatedAt:historyB.updatedAt,
     preview:"Ride Tram 28 through historic Alfama at sunrise.",
     model:historyB.model,
     messageCount:offlineResumedMessages.count,
     previewMatchRanges:[HistoryMatchRange(start:30,end:36)],
     firstMatchingMessageId:"lisbon-1"
    )
    self.store.receive(BridgeEvent(type:"history",history:[matchedLisbon],query:"alfama"))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    if let content=self.panel.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/history-search.png"))}
    if let escEvent=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:self.panel.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) {
     if let field=self.panel.contentView.flatMap(findSearchField),let editor=field.currentEditor() {
      editor.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
     } else {
      self.panel.sendEvent(escEvent)
     }
    }
    try? await Task.sleep(for:.milliseconds(150))
    let composerAfterEsc=self.panel.contentView.flatMap(composerIn)
    check("Pressing Esc with text in History search closes History in one keypress with draft intact and composer focused",
          !self.store.showingHistory && self.store.historyQuery.isEmpty && self.store.session.conversationId == historyB.id &&
          self.store.draft == "Unsent Lisbon note" && composerAfterEsc != nil && self.panel.firstResponder === composerAfterEsc)

    // Re-selecting the currently active conversation from a non-empty search query closes History,
    // scrolls directly to the first matching message near the top, and leaves the Latest pill available!
    self.store.openHistory()
    self.store.updateHistoryQuery("alfama")
    self.store.receive(BridgeEvent(type:"history",history:[matchedLisbon],query:"alfama"))
    try? await Task.sleep(for:.milliseconds(100))
    self.store.openSelectedHistoryConversation()
    let searchOpenCommand=self.store.fixtureCommands.last
    self.store.receive(BridgeEvent(
     type:"ready",
     conversationId:historyB.id,
     messages:offlineResumedMessages,
     models:ready.models,
     model:"gpt-6-sol",
     scrollToMessageId:"lisbon-1"
    ))
    try? await Task.sleep(for:.milliseconds(250))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    if let content=self.panel.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path+"/history-scroll-match.png"))}
    let matchedMessageVisible=(self.panel.contentView.map(findProse) ?? []).contains {
     $0.storage.string == "Ride Tram 28 through historic Alfama at sunrise." && !$0.visibleRect.isEmpty
    }
    check("Selecting a search match (including active conversation) scrolls to matching message with Latest pill available",
          !self.store.showingHistory &&
          searchOpenCommand == ["type":"openConversation","conversationId":historyB.id,"scrollToMessageId":"lisbon-1"] &&
          matchedMessageVisible && !self.store.followBottom && self.store.draft == "Unsent Lisbon note")

    self.store.openHistory()
    self.hide()
    let hiddenResetHistory = !self.store.showingHistory
    self.show()
    try? await Task.sleep(for:.milliseconds(150))
    let composerAfterHide=self.panel.contentView.flatMap(composerIn)
    check("Hiding Panel while History is open abandons History and focuses composer on reopen",
          hiddenResetHistory && !self.store.showingHistory && self.store.draft == "Unsent Lisbon note" &&
          composerAfterHide != nil && self.panel.firstResponder === composerAfterHide)

    self.store.send()
    self.store.openHistory()
    let blockedWhileStreaming = !self.store.showingHistory && self.store.session.streaming
    self.store.receive(BridgeEvent(type:"done",conversationId:historyB.id,executionID:self.store.session.executionID))
    check("History is blocked while an active turn is streaming",blockedWhileStreaming && self.store.session.canOpenHistory)

    // Individual deletion (#25): row delete button exposed on selected row, row click & ⌘⌫ confirmation/cancel,
    // deleting active conversation + deleting all saved conversations -> "No saved conversations yet" empty state,
    // and abandoning History lands cleanly on a fresh blank New Chat with clean Draft and composer focus.
    self.store.draft="Draft to discard on active delete"
    self.store.openHistory()
    self.store.receive(BridgeEvent(type:"history",history:[historyA,historyB],query:""))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let initialDeleteButtons=self.panel.contentView.map(findDeleteButtons) ?? []
    let deleteButtonExposedForSelectedRow=initialDeleteButtons.count == 1 &&
     initialDeleteButtons.first?.accessibilityIdentifier() == "history-delete-\(historyA.id)"
    self.store.moveHistorySelection(1) // select active historyB
    try? await Task.sleep(for:.milliseconds(100))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let movedDeleteButtons=self.panel.contentView.map(findDeleteButtons) ?? []
    let deleteButtonMovedToSelectedRow=movedDeleteButtons.count == 1 &&
     movedDeleteButtons.first?.accessibilityIdentifier() == "history-delete-\(historyB.id)"
    let cmdsBeforeDeletePrompt=self.store.fixtureCommands.count
    movedDeleteButtons.first?.performClick(nil)
    let promptedViaButton=self.store.pendingDeleteEntry == historyB && self.store.fixtureCommands.count == cmdsBeforeDeletePrompt
    self.store.cancelDeleteHistoryConversation()
    let cancelledDeleteKeepsState=self.store.pendingDeleteEntry == nil &&
     self.store.historyEntries == [historyA,historyB] &&
     self.store.session.conversationId == historyB.id &&
     self.store.draft == "Draft to discard on active delete" &&
     self.store.fixtureCommands.count == cmdsBeforeDeletePrompt
    check("History exposes delete button on selected row, opens confirmation on click, and cancels cleanly",
          deleteButtonExposedForSelectedRow && deleteButtonMovedToSelectedRow && promptedViaButton && cancelledDeleteKeepsState)

    // Trigger via ⌘⌫ path, confirm deletion of active historyB, then delete remaining historyA -> empty state,
    // then abandon History -> fresh blank New Chat with clean Draft and focused composer.
    let promptedViaShortcut=self.store.requestDeleteSelectedHistoryConversation() && self.store.pendingDeleteEntry == historyB
    self.store.confirmDeleteHistoryConversation()
    let deletedActiveCmd=self.store.fixtureCommands.last
    self.store.receive(BridgeEvent(
     type:"ready",
     conversationId:nil,
     messages:[],
     models:ready.models,
     model:"gpt-6-sol",
     notice:"New chat",
     clearedActiveConversation:true
    ))
    self.store.receive(BridgeEvent(type:"history",history:[historyA],clearedActiveConversation:true,query:""))
    try? await Task.sleep(for:.milliseconds(100))
    self.store.requestDeleteHistoryConversation(historyA)
    self.store.confirmDeleteHistoryConversation()
    let deletedLastCmd=self.store.fixtureCommands.last
    self.store.receive(BridgeEvent(type:"history",history:[],clearedActiveConversation:false,query:""))
    try? await Task.sleep(for:.milliseconds(150))
    self.panel.contentView?.layoutSubtreeIfNeeded();self.panel.displayIfNeeded()
    let emptyAfterDeleteRendered=self.store.fixtureHistoryEmptyTitle == "No saved conversations yet"
    let emptyAfterDeleteNoScroll=self.panel.contentView.map{!hasScrollView($0)} ?? false
    self.store.closeHistory()
    try? await Task.sleep(for:.milliseconds(150))
    let composerAfterDeleteAbandon=self.panel.contentView.flatMap(composerIn)
    check("Confirming deletion removes active conversation, shows empty state when all deleted, and abandons to blank New Chat",
          promptedViaShortcut &&
          deletedActiveCmd == ["type":"deleteConversation","conversationId":historyB.id] &&
          deletedLastCmd == ["type":"deleteConversation","conversationId":historyA.id] &&
          emptyAfterDeleteRendered && emptyAfterDeleteNoScroll &&
          !self.store.showingHistory && self.store.session.conversationId == nil &&
          self.store.session.messages.isEmpty && self.store.draft.isEmpty &&
          composerAfterDeleteAbandon != nil && self.panel.firstResponder === composerAfterDeleteAbandon)

    // Settings History retention & Clear All History wiring in fixture mode (restoring UserDefaults afterward).
    let savedRetentionRaw=self.preferences.defaults.object(forKey:"historyRetention")
    let savedRetentionPolicy=self.preferences.historyRetention
    let fifteenDaysAgo=HistoryEntry(id:"conv-15d",title:"Fifteen days ago",updatedAt:iso.string(from:smokeNow.addingTimeInterval(-15*86_400)),preview:"Older reply.",model:"gpt-6-luna",messageCount:2)
    self.store.receive(BridgeEvent(type:"history",history:[historyA,fifteenDaysAgo]))
    self.preferences.historyRetention = .days30
    self.preferences.refreshHistoryCount()
    let countRefreshed=self.preferences.savedHistoryCount == 2
    self.preferences.requestHistoryRetention(.days7)
    let promptedShrink=self.preferences.pendingHistoryConfirmation == .shortenRetention(target:.days7,previous:.days30,affectedCount:1)
    self.preferences.cancelHistoryConfirmation()
    let cancelledReverted=self.preferences.pendingHistoryConfirmation == nil && self.preferences.historyRetention == .days30
    self.preferences.requestHistoryRetention(.days7)
    self.preferences.confirmHistoryConfirmation()
    let confirmedPrune=self.store.fixtureCommands.last == ["type":"applyRetention","retention":"7d"]
    self.preferences.requestClearAllHistory()
    let promptedClearAll=self.preferences.pendingHistoryConfirmation == .clearAll(affectedCount:2)
    self.preferences.confirmHistoryConfirmation()
    let confirmedClearAll=self.store.fixtureCommands.last == ["type":"clearHistory"]
    self.preferences.historyRetention=savedRetentionPolicy
    if let savedRetentionRaw {self.preferences.defaults.set(savedRetentionRaw,forKey:"historyRetention")}
    else {self.preferences.defaults.removeObject(forKey:"historyRetention")}
    check("Settings History retention confirms shrink, reverts on cancel, and dispatches prune and Clear All",
          countRefreshed && promptedShrink && cancelledReverted && confirmedPrune && promptedClearAll && confirmedClearAll)

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
     // Details position (100 points from right edge beside Retry, or 46 points when alone).
     let detailsOffset:CGFloat=(self.store.session.canRetryOpenRouter || self.store.session.visibleCodexRetry != nil) ? 100 : 46
     let screen=NSPoint(x:self.panel.frame.maxX-detailsOffset,y:notice.accessibilityFrame().midY)
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
    let report:[String:Any]=["checks":checks,"passed":checks.count-failures,"failed":failures,"note":"Fixture UI harness. Does not verify physical hotkey, Space switches, login-item changes, or live response rendering." ]
    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path+"/report.json"))}
    self.hotkey.remove();exit(failures == 0 ? 0 : 1)
   }
  } catch {FileHandle.standardError.write(Data("UI smoke fixture failed: \(error)\n".utf8));exit(1)}
 }
}
