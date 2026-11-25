import AppKit
import SwiftUI

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
