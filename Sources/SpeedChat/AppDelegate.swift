import AppKit
import SwiftUI
import ChatCore

@MainActor final class FloatingPanel:NSPanel {
 override var canBecomeKey:Bool {true}
 override var canBecomeMain:Bool {true}
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
 let store=ChatStore()
 let preferences=Preferences()
 let scroll=TranscriptScroll()
 let hotkey=GlobalHotKey()
 var panel:FloatingPanel!
 var settingsWindow:NSWindow?
 var statusItem:NSStatusItem?
 var keyMonitor:Any?
 let fixture=CommandLine.arguments.contains("--ui-smoke")
 func applicationDidFinishLaunching(_ notification:Notification) {
  NSApp.setActivationPolicy(.accessory)
  if fixture && CommandLine.arguments.contains("--dark") {NSApp.appearance=NSAppearance(named:.darkAqua)}
  store.fixtureMode=fixture
  applyPreferences()
  panel=FloatingPanel(contentRect:NSRect(x:0,y:0,width:790,height:740),styleMask:[.titled,.closable,.resizable,.fullSizeContentView,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.title="SpeedChat";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true
  panel.isFloatingPanel=false;panel.level = .normal;panel.hidesOnDeactivate=true;panel.isReleasedWhenClosed=false
  panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.minSize=NSSize(width:580,height:480)
  panel.delegate=self
  panel.contentView=NSHostingView(rootView:PanelView(store:store,preferences:preferences,scroll:scroll,settings:{[weak self] in self?.showSettings()},dismiss:{[weak self] in self?.hide()}))
  if !fixture {panel.setFrameAutosaveName("SpeedChat.Panel");if !panel.setFrameUsingName("SpeedChat.Panel") {panel.center()}} else {panel.center()}
  hotkey.action={ [weak self] in self?.toggle() }
  preferences.updateHotkey={ [weak self] binding in try self?.hotkey.register(binding) }
  preferences.reconnect={ [weak self] in self?.applyPreferences();self?.store.connect() }
  preferences.reloadConfig={ [weak self] in
   guard let self else {return}
   self.store.reloadConfig()
   if let hosting=self.settingsWindow?.contentView {
    hosting.layoutSubtreeIfNeeded()
    self.settingsWindow?.setContentSize(hosting.fittingSize)
   }
  }
  createMainMenu()
  if !fixture {do {try hotkey.register(preferences.hotkey)} catch {preferences.error=error.localizedDescription};createMenu()}
  keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
   guard let self,self.panel.isKeyWindow,!(self.panel.firstResponder is RecorderButton) else {return event}
   switch KeyboardPolicy.action(code:event.keyCode,modifiers:event.modifierFlags.chatModifiers,streaming:self.store.session.streaming) {
   case .newChat:self.store.newChat();return nil
   case .stop:self.store.interrupt();return nil
   case .dismiss:self.hide();return nil
   case .pageUp:self.scroll.page(-1);return nil
   case .pageDown:self.scroll.page(1);return nil
   default:return event
   }
  }
  show()
  if fixture {Task { @MainActor in try? await Task.sleep(for:.milliseconds(700));self.runUISmoke() }}
 }
 func applyPreferences() {store.codexOverride=preferences.codexPath;store.developerMetrics=preferences.metrics}
 func createMainMenu() {
  let mainMenu=NSMenu()
  let appItem=NSMenuItem();mainMenu.addItem(appItem)
  let appMenu=NSMenu()
  let settingsItem=NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:",");settingsItem.target=self;appMenu.addItem(settingsItem)
  appMenu.addItem(.separator())
  let closeItem=NSMenuItem(title:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w");appMenu.addItem(closeItem)
  let quitItem=NSMenuItem(title:"Quit SpeedChat",action:#selector(quit),keyEquivalent:"q");quitItem.target=self;appMenu.addItem(quitItem)
  appItem.submenu=appMenu

  let editItem=NSMenuItem();mainMenu.addItem(editItem)
  let editMenu=NSMenu(title:"Edit")
  editMenu.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
  let redo=editMenu.addItem(withTitle:"Redo",action:Selector(("redo:")),keyEquivalent:"Z")
  redo.keyEquivalentModifierMask=[.command,.shift]
  editMenu.addItem(.separator())
  editMenu.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
  editMenu.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
  editMenu.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
  editMenu.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
  editItem.submenu=editMenu
  NSApp.mainMenu=mainMenu
 }
 func createMenu() {
  statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  let menuIcon:NSImage?={
   if let img=Bundle.main.image(forResource:"MenuBarIcon") {return img}
   let devPath=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("resources/MenuBarIcon@2x.png").path
   return NSImage(contentsOfFile:devPath)
  }()
  if let menuIcon {
   menuIcon.size=NSSize(width:22,height:18)
   menuIcon.isTemplate=true
   statusItem?.button?.image=menuIcon
   statusItem?.button?.setAccessibilityLabel("SpeedChat")
  } else {
   statusItem?.button?.image=NSImage(systemSymbolName:"bubble.left.and.bubble.right",accessibilityDescription:"SpeedChat")
  }
  let menu=NSMenu()
  for (title,selector,key) in [("Show / Hide SpeedChat",#selector(toggle),""),("New Chat",#selector(newChat),"n"),("Settings…",#selector(showSettings),",")] {
   let item=NSMenuItem(title:title,action:selector,keyEquivalent:key);item.target=self;menu.addItem(item)
  }
  menu.addItem(.separator());let quit=NSMenuItem(title:"Quit SpeedChat",action:#selector(quit),keyEquivalent:"q");quit.target=self;menu.addItem(quit)
  statusItem?.menu=menu
 }
 @objc func toggle() {panel.isVisible ? hide() : show()}
 func show() {
  store.show();NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
  panel.contentView?.layoutSubtreeIfNeeded()
  focusComposer()
  DispatchQueue.main.async { [weak self] in
   guard let self,self.panel.isVisible,self.panel.isKeyWindow else {return}
   self.focusComposer()
  }
 }
 private func focusComposer() {
  func find(_ view:NSView)->ComposerTextView? {
   if let composer=view as? ComposerTextView {return composer}
   return view.subviews.lazy.compactMap(find).first
  }
  if let composer=panel.contentView.flatMap(find) {
   composer.isEditable=true
   panel.makeFirstResponder(composer)
  }
 }
 func hide() {panel.orderOut(nil);store.hide()}
 func windowDidResignKey(_ notification:Notification) {
  guard notification.object as? NSWindow === panel else {return}
  hide()
 }
 func applicationDidResignActive(_ notification:Notification) {
  if panel.isVisible {hide()}
 }
 @objc func newChat() {show();store.newChat()}
 @objc func showSettings() {
  preferences.refreshLogin()
  if settingsWindow == nil {
   let hosting=NSHostingView(rootView:SettingsView(preferences:preferences))
   hosting.layoutSubtreeIfNeeded()
   let size=hosting.fittingSize
   let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable],backing:.buffered,defer:false)
   window.title="SpeedChat Settings";window.isReleasedWhenClosed=false;window.contentView=hosting;window.setContentSize(size);window.center();settingsWindow=window
  } else if let hosting=settingsWindow?.contentView {
   hosting.layoutSubtreeIfNeeded();settingsWindow?.setContentSize(hosting.fittingSize)
  }
  NSApp.activate(ignoringOtherApps:true);settingsWindow?.makeKeyAndOrderFront(nil)
 }
 @objc func quit() {NSApp.terminate(nil)}
 func windowShouldClose(_ sender:NSWindow)->Bool {if sender === panel {hide();return false};return true}
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
  hotkey.remove();if let keyMonitor {NSEvent.removeMonitor(keyMonitor)}
  store.stop {Task { @MainActor in NSApp.reply(toApplicationShouldTerminate:true) }}
  return .terminateLater
 }
}
