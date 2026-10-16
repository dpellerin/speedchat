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
 var body:some View {
  VStack(spacing:0) {header;Divider();transcript;Divider();footer}
   .frame(minWidth:400,minHeight:460)
   .background(colorScheme == .light ? Color.white : Color(nsColor:.windowBackgroundColor))
   .environment(\.openURL,OpenURLAction {url in NativeActions.open(url) ? .handled : .discarded})
   .onAppear {scroll.changed={near in store.followBottom=near}}
 }
 private var header:some View {
  let openAiModels=store.session.models.filter{!$0.isOpenRouter}
  let openRouterModels=store.session.models.filter{$0.isOpenRouter}
  return HStack(spacing:12) {
   DragHeader().frame(height:24).frame(minWidth:50,maxWidth:.infinity)
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
  }.padding(.horizontal,18).padding(.vertical,8)
 }
 private var transcript:some View {
  ScrollViewReader {proxy in
   ZStack(alignment:.bottomTrailing) {
    ScrollView {
     LazyVStack(alignment:.leading,spacing:18) {
      if store.session.messages.isEmpty {emptyState}
      ForEach(store.session.messages) {message in MessageView(message:message).id(message.id)}
      Color.clear.frame(height:1).id("bottom").background(ScrollProbe(controller:scroll))
     }.padding(20)
    }.onChange(of:store.session.messages) {old,messages in
     guard let last=messages.last else {return}
     if old.last?.id != last.id {
      scroll.userScrolled=false
      store.followBottom=true
     }
     guard store.followBottom && !scroll.userScrolled else {return}
     proxy.scrollTo(last.id,anchor:.top)
    }
    if !store.followBottom {Button {scroll.userScrolled=false;store.followBottom=true;proxy.scrollTo("bottom",anchor:.bottom)} label:{Label("Latest",systemImage:"arrow.down")}.buttonStyle(.borderedProminent).padding(14)}
   }
  }
 }
 private var emptyState:some View {
  VStack(spacing:14) {Image(systemName:"sparkles").font(.system(size:32)).foregroundStyle(Color.accentColor);Text("What’s on your mind?").font(.title2.weight(.medium));Text("A quiet space to ask, explore, and think.\nYour conversation resumes when you return.").foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity).padding(.top,80).padding(.bottom,40)
 }
 private var footer:some View {VStack(alignment:.leading,spacing:10) {status;composer;hints}.padding(18)}
 private var status:some View {
  HStack(spacing:7) {
   if store.session.busy || store.session.phase == .connecting {ProgressView().controlSize(.small)}
   Circle().fill(store.session.failed ? Color.red : (store.session.canInteract ? Color.green : Color.secondary)).frame(width:6,height:6)
   Text(store.session.notice).font(.caption).foregroundStyle(Color.secondary).lineLimit(2).textSelection(.enabled)
   Spacer(minLength:0)
   if store.session.failed && store.session.canInteract && !store.session.lastRequest.isEmpty {Button("Retry",action:store.retry).controlSize(.small)}
   if store.session.phase == .offline {Button("Reconnect",action:store.connect).controlSize(.small).disabled(store.session.busy)}
  }
 }
 private var composer:some View {
  HStack(alignment:.bottom,spacing:6) {
   ZStack(alignment:.topLeading) {
    if store.draft.isEmpty {Text(store.session.streaming ? "Press Esc to stop" : "Message SpeedChat").foregroundStyle(.tertiary).padding(.leading,14).padding(.top,13).allowsHitTesting(false)}
    Composer(text:$store.draft,height:$store.composerHeight,enabled:true,focusToken:store.focusToken,send:store.send).frame(height:store.composerHeight)
   }
   Button {if store.session.streaming {store.interrupt()} else {store.send()}} label:{Image(systemName:store.session.streaming ? "stop.fill" : "arrow.up").font(.system(size:15,weight:.semibold)).frame(width:30,height:30)}.buttonStyle(.borderedProminent).clipShape(Circle()).disabled(!store.session.streaming && (!store.session.canInteract || store.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)).help(store.session.streaming ? "Stop response" : "Send message").padding(8)
  }.background {RoundedRectangle(cornerRadius:16).fill(Color(nsColor:.textBackgroundColor).opacity(0.75))}.overlay(RoundedRectangle(cornerRadius:16).stroke(Color.secondary.opacity(0.2),lineWidth:1))
 }
 private var hints:some View {
  VStack(alignment:.leading,spacing:4) {
   Text("↵ Send   ⇧↵ Newline   ⌘N New   Esc Hide / Stop")
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
