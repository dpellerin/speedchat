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
   DispatchQueue.main.async {
    guard enabled,let window=view.window,WindowCoordinator.canFocusComposer(isVisible:window.isVisible,isOnActiveSpace:window.isOnActiveSpace,isKey:window.isKeyWindow) else {return}
    window.makeFirstResponder(view)
   }
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
@MainActor final class HistorySearchTextField:NSTextField {
 var pendingFocus=false
 var isFocusedInWindow:Bool {
  guard let window else {return false}
  return window.firstResponder === self || (currentEditor() != nil && window.firstResponder === currentEditor())
 }
 func requestFocus() {
  guard let window else {pendingFocus=true;return}
  guard WindowCoordinator.canFocusComposer(isVisible:window.isVisible,isOnActiveSpace:window.isOnActiveSpace,isKey:window.isKeyWindow) else {
   pendingFocus=false
   return
  }
  pendingFocus=false
  window.makeFirstResponder(self)
 }
 override func viewDidMoveToWindow() {
  super.viewDidMoveToWindow()
  if pendingFocus {
   DispatchQueue.main.async { [weak self] in self?.requestFocus() }
  }
 }
}
@MainActor final class HistorySearchBarNSView:NSView {
 let field=HistorySearchTextField()
 let clearButton=NSButton()
 var onClear:(()->Void)?
 override init(frame frameRect:NSRect) {
  super.init(frame:frameRect)
  field.isBordered=false
  field.drawsBackground=false
  field.focusRingType = .none
  field.font = .systemFont(ofSize:14)
  field.textColor = .labelColor
  field.placeholderString="Search conversations…"
  field.usesSingleLineMode=true
  field.lineBreakMode = .byTruncatingTail
  field.setAccessibilityLabel("Search conversations")
  field.setAccessibilityIdentifier("speedchat-history-search")
  field.translatesAutoresizingMaskIntoConstraints=false

  clearButton.isBordered=false
  clearButton.bezelStyle = .inline
  clearButton.image=NSImage(systemSymbolName:"xmark.circle.fill",accessibilityDescription:"Clear search")
  clearButton.contentTintColor = .secondaryLabelColor
  clearButton.imageScaling = .scaleProportionallyDown
  clearButton.toolTip="Clear search"
  clearButton.refusesFirstResponder=true
  clearButton.setAccessibilityLabel("Clear search")
  clearButton.setAccessibilityIdentifier("speedchat-history-clear-search")
  clearButton.target=self
  clearButton.action=#selector(clearPressed)
  clearButton.isHidden=true
  clearButton.translatesAutoresizingMaskIntoConstraints=false

  addSubview(field)
  addSubview(clearButton)
  NSLayoutConstraint.activate([
   field.leadingAnchor.constraint(equalTo:leadingAnchor),
   field.centerYAnchor.constraint(equalTo:centerYAnchor),
   field.trailingAnchor.constraint(equalTo:clearButton.leadingAnchor,constant:-6),
   clearButton.trailingAnchor.constraint(equalTo:trailingAnchor),
   clearButton.centerYAnchor.constraint(equalTo:centerYAnchor),
   clearButton.widthAnchor.constraint(equalToConstant:16),
   clearButton.heightAnchor.constraint(equalToConstant:16),
  ])
 }
 required init?(coder:NSCoder) {fatalError()}
 @objc private func clearPressed() {onClear?()}
}
struct HistorySearchField:NSViewRepresentable {
 @Binding var text:String
 var focusToken:Int
 var onClear:()->Void
 var onEscape:()->Void
 var onMoveUp:()->Void
 var onMoveDown:()->Void
 var onSubmit:()->Void
 func makeCoordinator() -> Coordinator {Coordinator(self)}
 func makeNSView(context:Context) -> HistorySearchBarNSView {
  let container=HistorySearchBarNSView()
  container.field.delegate=context.coordinator
  container.onClear=onClear
  return container
 }
 func updateNSView(_ container:HistorySearchBarNSView,context:Context) {
  context.coordinator.parent=self
  container.onClear=onClear
  let field=container.field
  if field.stringValue != text {field.stringValue=text}
  container.clearButton.isHidden=text.isEmpty
  if context.coordinator.focusToken != focusToken {
   context.coordinator.focusToken=focusToken
   field.pendingFocus=true
   DispatchQueue.main.async {field.requestFocus()}
  }
 }
 @MainActor final class Coordinator:NSObject,NSTextFieldDelegate {
  var parent:HistorySearchField
  var focusToken = -1
  init(_ parent:HistorySearchField) {self.parent=parent}
  func controlTextDidChange(_ obj:Notification) {
   guard let field=obj.object as? NSTextField else {return}
   if parent.text != field.stringValue {parent.text=field.stringValue}
  }
  func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
   if commandSelector == #selector(NSResponder.cancelOperation(_:)) {parent.onEscape();return true}
   if commandSelector == #selector(NSResponder.moveUp(_:)) {parent.onMoveUp();return true}
   if commandSelector == #selector(NSResponder.moveDown(_:)) {parent.onMoveDown();return true}
   if commandSelector == #selector(NSResponder.insertNewline(_:)) {parent.onSubmit();return true}
   return false
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
 func isNearBottom() -> Bool? {
  guard let scroll,let doc=scroll.documentView else {return nil}
  return scroll.contentView.bounds.maxY >= doc.bounds.height-70
 }
 func syncFollowBottom() {
  guard let scroll,let doc=scroll.documentView else {return}
  scroll.layoutSubtreeIfNeeded()
  changed?(scroll.contentView.bounds.maxY >= doc.bounds.height-70)
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
 func updateNSView(_ view:NSView,context:Context) {
  if view.enclosingScrollView != nil {controller.attach(view)}
  DispatchQueue.main.async {controller.attach(view)}
 }
}
