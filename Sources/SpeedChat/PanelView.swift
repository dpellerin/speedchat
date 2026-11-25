import SwiftUI
import AppKit
import ChatCore

@MainActor enum NativeActions {
 static func copy(_ text:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
 static func open(_ url:URL) -> Bool {guard let safe=LinkPolicy.url(url.absoluteString) else {return false};return NSWorkspace.shared.open(safe)}
 static func inline(_ text:String) -> AttributedString {
  var value=(try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  for run in value.runs {if let url=run.link,LinkPolicy.url(url.absoluteString) == nil {value[run.range].link=nil}}
  return value
 }
 static func attributedBlock(_ text:String,heading:Bool) -> NSAttributedString {
  let result=NSMutableAttributedString()
  let paragraph=NSMutableParagraphStyle()
  paragraph.lineSpacing=3
  let baseFont=heading ? NSFont.preferredFont(forTextStyle:.headline) : NSFont.systemFont(ofSize:15)
  let baseSize=baseFont.pointSize
  // SwiftUI rounds ascent and descent separately. TextKit's default rounds
  // their sum, losing a point per line and moving later link targets upward.
  paragraph.minimumLineHeight=ceil(baseFont.ascender)-floor(baseFont.descender)+ceil(baseFont.leading)
  let parsed=inline(text.isEmpty ? " " : text)
  for run in parsed.runs {
   let slice=String(parsed[run.range].characters)
   let intents=run.inlinePresentationIntent ?? []
   let font:NSFont
   if intents.contains(.code) {
    font=NSFont.monospacedSystemFont(ofSize:baseSize-1.5,weight:heading ? .semibold : .regular)
   } else if heading || intents.contains(.stronglyEmphasized) {
    let bold=heading ? baseFont : NSFont.systemFont(ofSize:baseSize,weight:.semibold)
    font=intents.contains(.emphasized) ? NSFontManager.shared.convert(bold,toHaveTrait:.italicFontMask) : bold
   } else if intents.contains(.emphasized) {
    font=NSFontManager.shared.convert(NSFont.systemFont(ofSize:baseSize),toHaveTrait:.italicFontMask)
   } else {
    font=NSFont.systemFont(ofSize:baseSize)
   }
   var attrs:[NSAttributedString.Key:Any]=[.font:font,.paragraphStyle:paragraph]
   if let url=run.link,let safe=LinkPolicy.url(url.absoluteString) {
    attrs[.link]=safe
    attrs[.cursor]=NSCursor.pointingHand
   }
   result.append(NSAttributedString(string:slice,attributes:attrs))
  }
  return result
 }
}

@MainActor final class LinkCursorView:NSView {
 let storage=NSTextStorage()
 let layoutManager=NSLayoutManager()
 let container=NSTextContainer(size:.zero)
 private var tracking:NSTrackingArea?
 private var showingHand=false
 override var isFlipped:Bool {true}
 override init(frame frameRect:NSRect) {
  super.init(frame:frameRect)
  container.lineFragmentPadding=0
  layoutManager.addTextContainer(container)
  storage.addLayoutManager(layoutManager)
 }
 required init?(coder:NSCoder) {fatalError()}
 override func hitTest(_ point:NSPoint) -> NSView? {nil}
 override func layout() {
  super.layout()
  container.containerSize=NSSize(width:max(1,bounds.width),height:CGFloat.greatestFiniteMagnitude)
  layoutManager.ensureLayout(for:container)
  window?.invalidateCursorRects(for:self)
 }
 override func resetCursorRects() {
  super.resetCursorRects()
  guard storage.length > 0 else {return}
  container.containerSize=NSSize(width:max(1,bounds.width),height:CGFloat.greatestFiniteMagnitude)
  layoutManager.ensureLayout(for:container)
  storage.enumerateAttribute(.link,in:NSRange(location:0,length:storage.length)) {value,range,_ in
   guard value != nil else {return}
   let glyphRange=layoutManager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
   let rect=layoutManager.boundingRect(forGlyphRange:glyphRange,in:container).insetBy(dx:-2,dy:-2)
   addCursorRect(rect,cursor:.pointingHand)
  }
 }
 override func updateTrackingAreas() {
  super.updateTrackingAreas()
  if let tracking {removeTrackingArea(tracking)}
  let area=NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.cursorUpdate,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
  addTrackingArea(area)
  tracking=area
 }
 func linkURL(at point:NSPoint) -> URL? {
  guard storage.length > 0 else {return nil}
  container.containerSize=NSSize(width:max(1,bounds.width),height:CGFloat.greatestFiniteMagnitude)
  layoutManager.ensureLayout(for:container)
  var fraction:CGFloat=0
  let glyphIndex=layoutManager.glyphIndex(for:point,in:container,fractionOfDistanceThroughGlyph:&fraction)
  guard glyphIndex < layoutManager.numberOfGlyphs else {return nil}
  let lineRect=layoutManager.lineFragmentUsedRect(forGlyphAt:glyphIndex,effectiveRange:nil)
  let glyphRect=layoutManager.boundingRect(forGlyphRange:NSRange(location:glyphIndex,length:1),in:container)
  let hitRect=glyphRect.insetBy(dx:-4,dy:-3).union(NSRect(x:glyphRect.minX-2,y:lineRect.minY,width:max(8,glyphRect.width+4),height:lineRect.height))
  guard hitRect.contains(point) else {return nil}
  let charIndex=layoutManager.characterIndexForGlyph(at:glyphIndex)
  guard charIndex < storage.length else {return nil}
  return storage.attribute(.link,at:charIndex,effectiveRange:nil) as? URL
 }
 private func updateCursor(with event:NSEvent) {
  let point=convert(event.locationInWindow,from:nil)
  if bounds.contains(point) && linkURL(at:point) != nil {
   showingHand=true
   NSCursor.pointingHand.set()
   DispatchQueue.main.async { [weak self] in
    if self?.showingHand == true {NSCursor.pointingHand.set()}
   }
  } else if showingHand {
   showingHand=false
   NSCursor.arrow.set()
  }
 }
 override func mouseMoved(with event:NSEvent) {updateCursor(with:event)}
 override func cursorUpdate(with event:NSEvent) {updateCursor(with:event)}
 override func mouseExited(with event:NSEvent) {
  if showingHand {showingHand=false;NSCursor.arrow.set()}
 }
}

struct LinkCursorProbe:NSViewRepresentable {
 let text:String
 let heading:Bool
 func makeNSView(context:Context) -> LinkCursorView {
  let view=LinkCursorView()
  view.storage.setAttributedString(NativeActions.attributedBlock(text,heading:heading))
  return view
 }
 func updateNSView(_ view:LinkCursorView,context:Context) {
  view.storage.setAttributedString(NativeActions.attributedBlock(text,heading:heading))
  view.needsLayout=true
 }
}

struct ProseView:View {
 let text:String
 var body:some View {
  VStack(alignment:.leading,spacing:5) {
   ForEach(Array(ProseBlocks.parse(text).enumerated()),id:\.offset) { _,block in
    if block.heading {
     Text(NativeActions.inline(block.text)).font(.headline).textSelection(.enabled)
      .overlay(LinkCursorProbe(text:block.text,heading:true)).padding(.top,5)
    } else {
     Text(NativeActions.inline(block.text.isEmpty ? " " : block.text)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
      .overlay(LinkCursorProbe(text:block.text,heading:false))
    }
   }
  }.font(.system(size:15)).lineSpacing(3)
 }
}
struct MessageView:View {
 let message:ChatMessage
 var body:some View {
  VStack(alignment:.leading,spacing:10) {
   HStack {Text(message.role == "user" ? "You" : "SpeedChat").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Spacer();Button {NativeActions.copy(message.text)} label:{Image(systemName:"doc.on.doc")}.buttonStyle(.plain).help("Copy message").accessibilityLabel("Copy message")}
   if message.role == "user" {Text(message.text).font(.system(size:15)).textSelection(.enabled)}
   else {ForEach(MarkdownBlocks.parse(message.text)) {part in
    if part.code {
     VStack(alignment:.leading,spacing:9) {
      HStack {Text(part.language.isEmpty ? "CODE" : part.language.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary);Spacer();Button {NativeActions.copy(part.text)} label:{Label("Copy",systemImage:"doc.on.doc")}.buttonStyle(.borderless).help("Copy code")}
      Divider()
      ScrollView(.horizontal) {Text(part.text).font(.system(size:13,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:true,vertical:false).frame(maxWidth:.infinity,alignment:part.language == "math" ? .center : .leading)}
     }.padding(12).background {RoundedRectangle(cornerRadius:10).fill(Color.secondary.opacity(0.1))}
    } else {ProseView(text:part.text)}
   }}
  }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background {RoundedRectangle(cornerRadius:14).fill(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.clear)}
 }
}
struct PanelView:View {
 @ObservedObject var store:ChatStore
 @ObservedObject var preferences:Preferences
 @ObservedObject var scroll:TranscriptScroll
 var settings:()->Void
 var dismiss:()->Void
 @Environment(\.colorScheme) private var colorScheme
 // Use the property wrapper, not the newer SDK's same-named State macro.
 private typealias ViewState<Value> = SwiftUI.State<Value>
 @ViewState private var showingErrorDetails=false
 var body:some View {
  VStack(spacing:0) {
   header
   Divider()
   if store.showingHistory {
    historySearchBar
    Divider()
    historyList
    Divider()
    historyFooter
   } else {
    transcript
    Divider()
    footer
   }
  }
   .frame(minWidth:400,minHeight:460)
   .background(colorScheme == .light ? Color.white : Color(nsColor:.windowBackgroundColor))
   .environment(\.openURL,OpenURLAction {url in NativeActions.open(url) ? .handled : .discarded})
   .onAppear {scroll.changed={near in store.followBottom=near}}
   .alert(
    "Delete conversation?",
    isPresented:Binding(
     get:{store.pendingDeleteEntry != nil},
     set:{if !$0 {store.cancelDeleteHistoryConversation()}}
    ),
    presenting:store.pendingDeleteEntry
   ) { _ in
    Button("Delete",role:.destructive) {
     store.confirmDeleteHistoryConversation()
    }
    Button("Cancel",role:.cancel) {
     store.cancelDeleteHistoryConversation()
    }
   } message: {entry in
    Text("“\(entry.title)” will be permanently deleted from SpeedChat. External Codex threads will not be touched.")
   }
 }
 private var header:some View {
  let openAiModels=store.session.models.filter{!$0.isOpenRouter}
  let openRouterModels=store.session.models.filter{$0.isOpenRouter}
  return HStack(spacing:12) {
   if store.showingHistory {
    // Clear the macOS window traffic lights in fullSizeContentView titlebars.
    Spacer().frame(width:60)
    Button {store.closeHistory()} label:{Label("Back",systemImage:"chevron.left").font(.callout)}
     .buttonStyle(.borderless)
     .help("Return to current conversation (Esc)")
     .accessibilityIdentifier("speedchat-history-back")
    DragHeader().frame(height:24).frame(minWidth:50,maxWidth:.infinity)
    Button {store.newChat()} label:{Label("New Chat",systemImage:"square.and.pencil").font(.callout)}
     .buttonStyle(.borderless)
     .disabled(!store.session.canInteract)
     .help("Start a new conversation (⌘N)")
     .accessibilityIdentifier("speedchat-history-new-chat")
   } else {
    DragHeader().frame(height:24).frame(minWidth:50,maxWidth:.infinity)
    Button {store.openHistory()} label:{Label("History",systemImage:"clock.arrow.circlepath").font(.callout)}
     .buttonStyle(.borderless)
     .disabled(!store.session.canOpenHistory)
     .help("Conversation History (⌘K)")
     .accessibilityLabel("Conversation History")
     .accessibilityIdentifier("speedchat-history-button")
    Menu {
     if !openAiModels.isEmpty {
      Section("OpenAI") {
       ForEach(openAiModels) {model in
        Button {store.selectModel(model.model)} label:{if model.model == store.session.selectedModel {Label(model.displayName,systemImage:"checkmark")} else {Text(model.displayName)}}
       }
      }
     }
     Section("OpenRouter") {
      if openRouterModels.isEmpty {
       Button("Configure OpenRouter in Settings…") {settings()}
      } else {
       ForEach(openRouterModels) {model in
        Button {store.selectModel(model.model)} label:{if model.model == store.session.selectedModel {Label(model.displayName,systemImage:"checkmark")} else {Text(model.displayName)}}
       }
       Divider()
       Button("OpenRouter Settings…") {settings()}
      }
     }
    } label:{Label(modelLabel,systemImage:"sparkle").font(.callout)}.disabled(!store.session.canInteract || store.session.models.isEmpty).help("Select the model for your next message")
   }
  }.padding(.horizontal,18).padding(.vertical,8)
 }
 private var historySearchBar:some View {
  HStack(spacing:8) {
   Image(systemName:"magnifyingglass")
    .font(.system(size:13))
    .foregroundStyle(.secondary)
   HistorySearchField(
    text:Binding(
     get:{store.historyQuery},
     set:{store.updateHistoryQuery($0)}
    ),
    focusToken:store.historyFocusToken,
    onClear:{store.clearHistoryQuery()},
    onEscape:{store.closeHistory()},
    onMoveUp:{store.moveHistorySelection(-1)},
    onMoveDown:{store.moveHistorySelection(1)},
    onSubmit:{store.openSelectedHistoryConversation()}
   )
   .frame(height:22)
  }
  .padding(.horizontal,12)
  .padding(.vertical,8)
  .background {
   RoundedRectangle(cornerRadius:10)
    .fill(Color(nsColor:.textBackgroundColor).opacity(0.75))
  }
  .overlay {
   RoundedRectangle(cornerRadius:10)
    .stroke(Color.secondary.opacity(0.2),lineWidth:1)
  }
  .padding(.horizontal,14)
  .padding(.vertical,10)
 }
 private var historyList:some View {
  Group {
   if store.historyEntries.isEmpty {
    VStack(spacing:12) {
     if store.hasActiveHistoryQuery {
      Image(systemName:"magnifyingglass").font(.system(size:30)).foregroundStyle(.secondary)
      Text("No matching conversations").font(.title3.weight(.medium)).textSelection(.enabled)
       .accessibilityLabel("No matching conversations")
       .accessibilityIdentifier("speedchat-history-no-matches")
      Text("Try different words or clear the search.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
     } else {
      Image(systemName:"clock.arrow.circlepath").font(.system(size:30)).foregroundStyle(.secondary)
      Text("No saved conversations yet").font(.title3.weight(.medium)).textSelection(.enabled)
       .accessibilityLabel("No saved conversations yet")
       .accessibilityIdentifier("speedchat-history-empty")
      Text("Conversations with at least one message appear here.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
     }
    }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(24)
   } else {
    ScrollViewReader {proxy in
     ScrollView {
      LazyVStack(alignment:.leading,spacing:6) {
       ForEach(Array(store.historyEntries.enumerated()),id:\.element.id) {index,entry in
        HistoryRowView(
         entry:entry,
         isCurrent:entry.id == store.session.conversationId,
         isSelected:index == store.selectedHistoryIndex,
         open:{
          store.openHistoryConversation(
           id:entry.id,
           scrollToMessageId:store.hasActiveHistoryQuery ? entry.firstMatchingMessageId : nil
          )
         },
         delete:{
          store.requestDeleteHistoryConversation(entry)
         }
        ).id(entry.id)
       }
      }.padding(14)
     }
     .onChange(of:store.selectedHistoryIndex) {_,index in
      guard store.historyEntries.indices.contains(index) else {return}
      proxy.scrollTo(store.historyEntries[index].id,anchor:nil)
     }
    }
   }
  }.frame(maxWidth:.infinity,maxHeight:.infinity)
 }
 private var historyFooter:some View {
  HStack {
   Text("↑↓ Navigate   ↵ Open   ⌘⌫ Delete   ⌘N New   Esc Back").font(.system(size:10)).foregroundStyle(.secondary)
   Spacer(minLength:0)
  }.padding(.horizontal,18).padding(.vertical,10)
 }
 private var transcript:some View {
  // Rebuild the scroll container when loading a conversation so its lazy
  // layout and clip position cannot carry over from the previous transcript.
  ScrollViewReader {proxy in
   ZStack(alignment:.bottomTrailing) {
    ScrollView {
     LazyVStack(alignment:.leading,spacing:18) {
      if store.session.messages.isEmpty {emptyState}
      ForEach(store.session.messages) {message in MessageView(message:message).id(message.id)}
      Color.clear.frame(height:1).id("bottom")
     }.padding(20).background(ScrollProbe(controller:scroll))
    }.onChange(of:store.session.messages) {old,messages in
     guard let last=messages.last else {return}
     if old.last?.id != last.id {
      scroll.userScrolled=false
      store.followBottom=true
     }
     guard store.followBottom && !scroll.userScrolled else {return}
     proxy.scrollTo(last.id,anchor:.top)
    }
    .task(id:store.session.transcriptID) {
     guard !store.session.messages.isEmpty else {
      store.clearScrollTarget()
      scroll.userScrolled=false
      store.followBottom=true
      return
     }
     if let targetId=store.consumeScrollTarget(),
        store.session.messages.contains(where:{$0.id == targetId}) {
      scroll.userScrolled=true
      proxy.scrollTo(targetId,anchor:.center)
      await Task.yield()
      proxy.scrollTo(targetId,anchor:.center)
      try? await Task.sleep(for:.milliseconds(30))
      proxy.scrollTo(targetId,anchor:.center)
      scroll.syncFollowBottom()
     } else {
      scroll.userScrolled=false
      store.followBottom=true
      proxy.scrollTo("bottom",anchor:.bottom)
      await Task.yield()
      proxy.scrollTo("bottom",anchor:.bottom)
     }
    }
    if !store.followBottom {Button {store.clearScrollTarget();scroll.userScrolled=false;store.followBottom=true;proxy.scrollTo("bottom",anchor:.bottom)} label:{Label("Latest",systemImage:"arrow.down")}.buttonStyle(.borderedProminent).padding(14).accessibilityIdentifier("speedchat-latest-button")}
   }
  }.id(store.session.transcriptID)
 }
 private var emptyState:some View {
  VStack(spacing:14) {Image(systemName:"sparkles").font(.system(size:32)).foregroundStyle(Color.accentColor);Text("What’s on your mind?").font(.title2.weight(.medium));Text("A quiet space to ask, explore, and think.\nYour conversation resumes when you return.").foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity).padding(.top,80).padding(.bottom,40)
 }
 private var footer:some View {VStack(alignment:.leading,spacing:10) {status;composer;hints}.padding(18)}
 private var status:some View {
  HStack(spacing:7) {
   if store.session.busy || store.session.phase == .connecting {ProgressView().controlSize(.small)}
   Circle().fill(store.session.failed ? Color.red : (store.session.canInteract ? Color.green : Color.secondary)).frame(width:6,height:6)
   Text(store.session.notice).font(.caption).foregroundStyle(store.session.failed ? Color.red : Color.secondary).lineLimit(2).textSelection(.enabled)
    .accessibilityLabel(Text(store.session.notice))
    .accessibilityIdentifier("speedchat-status")
    .onChange(of:store.session.notice,initial:true) {_,notice in
     if store.fixtureMode {store.fixtureStatusNotice=notice}
    }
   Spacer(minLength:0)
   if store.session.failed {
    Button("Details") {showingErrorDetails=true}.controlSize(.small).accessibilityLabel("Show error details")
     .popover(isPresented:$showingErrorDetails,arrowEdge:.top) {
      VStack(alignment:.leading,spacing:12) {
       HStack {
        Text("Request failed").font(.headline)
        Spacer()
        Button {NativeActions.copy(store.session.errorDetails)} label:{Label("Copy",systemImage:"doc.on.doc")}.help("Copy full error").accessibilityLabel("Copy full error")
       }
       ScrollView {
        Text(store.session.errorDetails).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
       }.frame(height:220)
      }.padding(16).frame(width:380)
     }
     .onChange(of:store.session.notice) {showingErrorDetails=false}
   }
   if store.session.visibleCodexRetry?.action == .resend {Button("Resend",action:store.resend).controlSize(.small)}
   else if store.session.visibleCodexRetry != nil || store.session.canRetryOpenRouter {Button("Retry",action:store.retry).controlSize(.small)}
   if store.session.phase == .offline {Button("Reconnect",action:store.connect).controlSize(.small).disabled(store.session.busy)}
  }
 }
 private var composer:some View {
  HStack(alignment:.bottom,spacing:6) {
   ZStack(alignment:.topLeading) {
    if store.draft.isEmpty {Text(store.session.streaming ? "Press Esc to stop" : "Message SpeedChat").foregroundStyle(.tertiary).padding(.leading,14).padding(.top,13).allowsHitTesting(false)}
    Composer(text:$store.draft,height:$store.composerHeight,enabled:true,focusToken:store.focusToken,send:store.send).frame(height:store.composerHeight)
   }
   Button {if store.session.streaming {store.interrupt()} else {store.send()}} label:{Image(systemName:store.session.streaming ? "stop.fill" : "arrow.up").font(.system(size:15,weight:.semibold)).frame(width:30,height:30)}.buttonStyle(.borderedProminent).clipShape(Circle()).disabled(!store.session.streaming && (!store.session.canSend || store.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)).help(store.session.streaming ? "Stop response" : "Send message").padding(8)
  }.background {RoundedRectangle(cornerRadius:16).fill(Color(nsColor:.textBackgroundColor).opacity(0.75))}.overlay(RoundedRectangle(cornerRadius:16).stroke(Color.secondary.opacity(0.2),lineWidth:1))
 }
 private var hints:some View {
  VStack(alignment:.leading,spacing:4) {
   Text("↵ Send   ⇧↵ Newline   ⌘K History   ⌘N New   Esc Hide / Stop")
   if preferences.metrics {Text("Ready \(Int(store.readyMs)) ms · First \(Int(store.session.metrics["first-token"] ?? 0)) ms · Total \(Int(store.session.metrics["response"] ?? 0)) ms").help("Cold starts: \(store.coldStarts), warm reopens: \(store.warmReopens)")}
  }.font(.system(size:10)).foregroundStyle(.secondary)
 }
 private var modelLabel:String {
  let active=store.session.activeModel
  let label=store.session.models.first(where:{$0.model == active})?.displayName ?? active
  return label.isEmpty ? "Model" : label + (active != store.session.selectedModel ? " · routed" : "")
 }
}
struct DragHeader:NSViewRepresentable {
 func makeNSView(context:Context)->HeaderDragView {HeaderDragView()}
 func updateNSView(_ view:HeaderDragView,context:Context) {}
}
@MainActor final class HeaderDragView:NSView {
 override func mouseDown(with event:NSEvent) {window?.performDrag(with:event)}
}

@MainActor private enum HistoryTimeFormatter {
 private static let formatter:RelativeDateTimeFormatter={
  let value=RelativeDateTimeFormatter()
  value.unitsStyle = .abbreviated
  return value
 }()
 static func relativeString(for isoTimestamp:String,now:Date=Date()) -> String {
  guard let date=StateStore.parseTimestamp(isoTimestamp) else {return ""}
  if abs(now.timeIntervalSince(date)) < 45 {return "Just now"}
  return formatter.localizedString(for:date,relativeTo:now)
 }
}

private struct HistoryRowView:View {
 let entry:HistoryEntry
 let isCurrent:Bool
 let isSelected:Bool
 let open:()->Void
 let delete:()->Void
 private typealias ViewState<Value> = SwiftUI.State<Value>
 @ViewState private var hovered=false
 var body:some View {
  HStack(alignment:.center,spacing:8) {
   Button(action:open) {
    VStack(alignment:.leading,spacing:4) {
     HStack(spacing:8) {
      Text(Self.highlighted(entry.title,ranges:entry.titleMatchRanges,fontSize:14,highlightWeight:.bold))
       .font(.system(size:14,weight:.semibold))
       .foregroundStyle(.primary)
       .lineLimit(1)
      if isCurrent {
       Text("Current")
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal,6)
        .padding(.vertical,2)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
      }
      Spacer(minLength:8)
      Text(HistoryTimeFormatter.relativeString(for:entry.updatedAt))
       .font(.caption)
       .foregroundStyle(.secondary)
       .lineLimit(1)
     }
     if !entry.preview.isEmpty {
      Text(Self.highlighted(entry.preview,ranges:entry.previewMatchRanges,fontSize:13,highlightWeight:.semibold))
       .font(.system(size:13))
       .foregroundStyle(.secondary)
       .lineLimit(2)
       .multilineTextAlignment(.leading)
     }
    }
    .frame(maxWidth:.infinity,alignment:.leading)
    .contentShape(Rectangle())
   }
   .buttonStyle(.plain)
   .accessibilityIdentifier("history-row-\(entry.id)")

   if hovered || isSelected {
    HistoryRowDeleteButton(
     conversationId:entry.id,
     title:entry.title,
     action:delete
    )
    .frame(width:24,height:24)
   }
  }
  .padding(.horizontal,12)
  .padding(.vertical,10)
  .background {
   RoundedRectangle(cornerRadius:10)
    .fill(isSelected ? Color.accentColor.opacity(0.14) : (hovered ? Color.secondary.opacity(0.08) : Color.clear))
  }
  .overlay {
   RoundedRectangle(cornerRadius:10)
    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear,lineWidth:1)
  }
  .contentShape(RoundedRectangle(cornerRadius:10))
  .onHover {hovered=$0}
 }

 private static func highlighted(
  _ text:String,
  ranges:[HistoryMatchRange],
  fontSize:CGFloat,
  highlightWeight:Font.Weight
 ) -> AttributedString {
  var attributed=AttributedString(text)
  guard !ranges.isEmpty else {return attributed}
  let totalCount=text.count
  for range in ranges {
   guard range.start >= 0,range.end > range.start,range.end <= totalCount else {continue}
   let lower=text.index(text.startIndex,offsetBy:range.start)
   let upper=text.index(text.startIndex,offsetBy:range.end)
   guard let attrLower=AttributedString.Index(lower,within:attributed),
         let attrUpper=AttributedString.Index(upper,within:attributed) else {continue}
   attributed[attrLower..<attrUpper].foregroundColor = .primary
   attributed[attrLower..<attrUpper].backgroundColor = Color.accentColor.opacity(0.22)
   attributed[attrLower..<attrUpper].font = .system(size:fontSize,weight:highlightWeight)
  }
  return attributed
 }
}

@MainActor final class HistoryDeleteNSButton:NSButton {
 var onDelete:(()->Void)?
 private var tracking:NSTrackingArea?
 private var isHovered=false {
  didSet {
   contentTintColor=isHovered ? .systemRed : .secondaryLabelColor
   layer?.backgroundColor=isHovered ? NSColor.systemRed.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
  }
 }
 override init(frame frameRect:NSRect) {
  super.init(frame:frameRect)
  isBordered=false
  bezelStyle = .inline
  wantsLayer=true
  layer?.cornerRadius=6
  image=NSImage(systemSymbolName:"trash",accessibilityDescription:"Delete conversation")
  symbolConfiguration=NSImage.SymbolConfiguration(pointSize:12,weight:.regular)
  contentTintColor = .secondaryLabelColor
  imageScaling = .scaleNone
  toolTip="Delete conversation (⌘⌫)"
  refusesFirstResponder=true
  target=self
  action=#selector(pressed)
 }
 required init?(coder:NSCoder) {fatalError()}
 override func updateTrackingAreas() {
  super.updateTrackingAreas()
  if let tracking {removeTrackingArea(tracking)}
  let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
  addTrackingArea(area)
  tracking=area
 }
 override func mouseEntered(with event:NSEvent) {isHovered=true}
 override func mouseExited(with event:NSEvent) {isHovered=false}
 @objc private func pressed() {onDelete?()}
}

private struct HistoryRowDeleteButton:NSViewRepresentable {
 let conversationId:String
 let title:String
 let action:()->Void
 func makeNSView(context:Context)->HistoryDeleteNSButton {
  let button=HistoryDeleteNSButton()
  update(button)
  return button
 }
 func updateNSView(_ button:HistoryDeleteNSButton,context:Context) {
  update(button)
 }
 private func update(_ button:HistoryDeleteNSButton) {
  button.onDelete=action
  button.setAccessibilityLabel("Delete \(title)")
  button.setAccessibilityIdentifier("history-delete-\(conversationId)")
 }
}
