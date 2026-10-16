import AppKit
import SwiftUI
import ChatCore
extension NSEvent.ModifierFlags {
 var chatModifiers:KeyModifiers {
  var result:KeyModifiers=[]
  if contains(.shift) {result.insert(.shift)};if contains(.command) {result.insert(.command)}
  if contains(.control) {result.insert(.control)};if contains(.option) {result.insert(.option)}
  return result
 }
}
@MainActor final class ComposerTextView:NSTextView {
 var send:(()->Void)?
 override func keyDown(with event:NSEvent) {
  switch KeyboardPolicy.action(code:event.keyCode,modifiers:event.modifierFlags.chatModifiers) {
  case .send:send?()
  case .newline:insertNewlineIgnoringFieldEditor(nil)
  default:super.keyDown(with:event)
  }
 }
}
struct Composer:NSViewRepresentable {
 @Binding var text:String
 @Binding var height:CGFloat
 var enabled:Bool
 var focusToken:Int
 var send:()->Void
 func makeCoordinator() -> Coordinator {Coordinator(self)}
 func makeNSView(context:Context) -> NSScrollView {
  let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
  let view=ComposerTextView();view.isRichText=false;view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false;view.isAutomaticTextReplacementEnabled=false
  view.font = .systemFont(ofSize:15);view.textColor = .labelColor;view.backgroundColor = .clear;view.drawsBackground=false
  view.textContainerInset=NSSize(width:10,height:10);view.isVerticallyResizable=true;view.isHorizontallyResizable=false
  view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
  view.delegate=context.coordinator;scroll.documentView=view;context.coordinator.view=view
  view.setAccessibilityLabel("Message SpeedChat");return scroll
 }
 func updateNSView(_ scroll:NSScrollView,context:Context) {
  context.coordinator.parent=self
  guard let view=scroll.documentView as? ComposerTextView else {return}
  if view.string != text {view.string=text;context.coordinator.measure()}
  view.isEditable=enabled;view.send=send
  if context.coordinator.focusToken != focusToken {
   context.coordinator.focusToken=focusToken
   DispatchQueue.main.async {if enabled {view.window?.makeFirstResponder(view)}}
  }
 }
 @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
  var parent:Composer
  weak var view:ComposerTextView?
  var focusToken = -1
  init(_ parent:Composer) {self.parent=parent}
  func textDidChange(_ notification:Notification) {guard let view else {return};parent.text=view.string;measure()}
  func measure() {
   guard let view,let layout=view.layoutManager,let container=view.textContainer else {return}
   layout.ensureLayout(for:container)
   let value=min(160,max(48,layout.usedRect(for:container).height+24))
   DispatchQueue.main.async {if abs(self.parent.height-value)>1 {self.parent.height=value}}
  }
 }
}
@MainActor final class TranscriptScroll:ObservableObject {
 weak var scroll:NSScrollView?
 var changed:((Bool)->Void)?
 var observer:NSObjectProtocol?
 var liveStartObserver:NSObjectProtocol?
 var liveEndObserver:NSObjectProtocol?
 var userScrolling=false
 var userScrolled=false
 func attach(_ view:NSView) {
  guard let found=view.enclosingScrollView, found !== scroll else {return}
  for token in [observer,liveStartObserver,liveEndObserver].compactMap({$0}) {NotificationCenter.default.removeObserver(token)}
  scroll=found;found.contentView.postsBoundsChangedNotifications=true
  observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:found.contentView,queue:.main) { [weak self] _ in
   MainActor.assumeIsolated {
    guard let self,let scroll=self.scroll,let doc=scroll.documentView else {return}
    // Geometry changes from streamed content are not evidence of user scroll intent.
    if self.userScrolling || NSApp.currentEvent?.type == .scrollWheel {
     self.userScrolled=true
     self.changed?(scroll.contentView.bounds.maxY >= doc.bounds.height-70)
    }
   }
  }
  liveStartObserver=NotificationCenter.default.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:found,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.userScrolling=true;self?.userScrolled=true} }
  liveEndObserver=NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:found,queue:.main) { [weak self] _ in MainActor.assumeIsolated {
   guard let self,let scroll=self.scroll,let doc=scroll.documentView else {return}
   self.changed?(scroll.contentView.bounds.maxY >= doc.bounds.height-70);self.userScrolling=false
  }}
 }
 func page(_ direction:CGFloat) {
  guard let scroll,let doc=scroll.documentView else {return}
  userScrolled=true
  let clip=scroll.contentView
  let y=max(0,min(max(0,doc.bounds.height-clip.bounds.height),clip.bounds.minY+direction*clip.bounds.height*0.8))
  clip.scroll(to:NSPoint(x:0,y:y));scroll.reflectScrolledClipView(clip)
  changed?(clip.bounds.maxY >= doc.bounds.height-70)
 }
}
struct ScrollProbe:NSViewRepresentable {
 var controller:TranscriptScroll
 func makeNSView(context:Context) -> NSView {NSView()}
 func updateNSView(_ view:NSView,context:Context) {DispatchQueue.main.async {controller.attach(view)}}
}
