import AppKit
import Carbon
import SwiftUI

struct HotKeyBinding: Codable, Equatable {
 var keyCode:UInt32
 var modifiers:UInt32
 var label:String
 static let standard=Self(keyCode:49,modifiers:UInt32(optionKey),label:"⌥ Space")
}
@MainActor final class GlobalHotKey {
 private var reference:EventHotKeyRef?
 private var handler:EventHandlerRef?
 var action:(()->Void)?
 var binding=HotKeyBinding.standard
 init() {
  var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
  InstallEventHandler(GetApplicationEventTarget(), {_,_,context in
   guard let context else {return OSStatus(eventNotHandledErr)}
   MainActor.assumeIsolated {Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action?()}
   return noErr
  },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
 }
 func register(_ next:HotKeyBinding) throws {
  if let reference {UnregisterEventHotKey(reference);self.reference=nil}
  let id=EventHotKeyID(signature:0x4D434854,id:1)
  let result=RegisterEventHotKey(next.keyCode,next.modifiers,id,GetApplicationEventTarget(),0,&reference)
  if result != noErr {
   _ = RegisterEventHotKey(binding.keyCode,binding.modifiers,id,GetApplicationEventTarget(),0,&reference)
   throw NSError(domain:"SpeedChat.HotKey",code:Int(result),userInfo:[NSLocalizedDescriptionKey:"That shortcut is unavailable (Carbon \(result)). Choose a different combination."])
  }
  binding=next
 }
 func remove() {if let reference {UnregisterEventHotKey(reference)};if let handler {RemoveEventHandler(handler)};reference=nil;handler=nil}
}
@MainActor final class RecorderButton:NSButton {
 var recorded:((HotKeyBinding)->Void)?
 var recording=false
 override var acceptsFirstResponder:Bool {true}
 override func mouseDown(with event:NSEvent) {recording=true;title="Press shortcut…";window?.makeFirstResponder(self)}
 override func keyDown(with event:NSEvent) {
  guard recording else {super.keyDown(with:event);return}
  if event.keyCode == 53 {recording=false;title="Record shortcut";return}
  let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
  guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {title="Include ⌘, ⌥ or ⌃";return}
  var modifiers:UInt32=0,label=""
  if flags.contains(.control) {modifiers |= UInt32(controlKey);label += "⌃"}
  if flags.contains(.option) {modifiers |= UInt32(optionKey);label += "⌥"}
  if flags.contains(.shift) {modifiers |= UInt32(shiftKey);label += "⇧"}
  if flags.contains(.command) {modifiers |= UInt32(cmdKey);label += "⌘"}
  let key=event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
  recording=false;recorded?(HotKeyBinding(keyCode:UInt32(event.keyCode),modifiers:modifiers,label:label+" "+key))
 }
}
struct ShortcutRecorder:NSViewRepresentable {
 var label:String
 var recorded:(HotKeyBinding)->Void
 func makeNSView(context:Context) -> RecorderButton {let button=RecorderButton();button.bezelStyle = .rounded;return button}
 func updateNSView(_ button:RecorderButton,context:Context) {if !button.recording {button.title=label};button.recorded=recorded}
}
