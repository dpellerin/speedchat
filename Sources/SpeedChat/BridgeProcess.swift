import Foundation
import Darwin
import ChatCore

/// All process and pipe operations run on the private serial queue. Never waits on the UI thread.
final class BridgeProcess: @unchecked Sendable {
 private let queue=DispatchQueue(label:"SpeedChat.bridge",qos:.userInitiated)
 private var process:Process?
 private var input:FileHandle?
 private var framer=JSONLFramer()
 private var closing=false
 private var failed=false
 private var closeCompletion:(@Sendable ()->Void)?
 private var onEvent: (@Sendable (BridgeEvent)->Void)?
 private static func isExecutable(_ path:String)->Bool {
  FileManager.default.isExecutableFile(atPath:path) && ((try? URL(fileURLWithPath:path).resolvingSymlinksInPath().resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true)
 }
 func start(bridge:String,nodeOverride:String,codexOverride:String,onEvent:@escaping @Sendable (BridgeEvent)->Void) {
  queue.async { [self] in
   self.onEvent=onEvent
   do {
    let home=FileManager.default.homeDirectoryForCurrentUser.path
    let inherited=ProcessInfo.processInfo.environment
    let entries=(try? FileManager.default.contentsOfDirectory(atPath:home+"/.hermes/tools")) ?? []
    let node=try RuntimeDiscovery.find(name:"node",override:nodeOverride,home:home,path:inherited["PATH"] ?? "",hermesEntries:entries,exists:Self.isExecutable)
    let codex=try RuntimeDiscovery.find(name:"codex",override:codexOverride,home:home,path:inherited["PATH"] ?? "",exists:Self.isExecutable)
    guard FileManager.default.fileExists(atPath:bridge) else {throw RuntimeDiscovery.DiscoveryError.missing("Bundled bridge")}
    let child=Process(), stdin=Pipe(), stdout=Pipe(), stderr=Pipe()
    child.executableURL=URL(fileURLWithPath:node);child.arguments=[bridge]
    child.currentDirectoryURL=URL(fileURLWithPath:URL(fileURLWithPath:bridge).deletingLastPathComponent().path)
    var env=RuntimeDiscovery.environment(inherited,home:home);env["SPEEDCHAT_CODEX"]=codex
    child.environment=env;child.standardInput=stdin;child.standardOutput=stdout;child.standardError=stderr
    // Convert a closed-pipe write into a recoverable EPIPE instead of terminating the macOS app.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
    input=stdin.fileHandleForWriting;process=child
    stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in
     let data=handle.availableData
     self?.queue.async { [weak self] in self?.read(data,handle:handle) }
    }
    // Drain diagnostics without exposing raw backend logs or inherited configuration to the UI.
    stderr.fileHandleForReading.readabilityHandler={ handle in if handle.availableData.isEmpty {handle.readabilityHandler=nil} }
    child.terminationHandler={ [weak self] child in self?.queue.async { [weak self] in
     guard let self else {return}
     self.process=nil;self.input=nil
     if self.closing {self.completeClose()}
     if !self.closing {self.fail("The chat backend exited (\(child.terminationStatus)). Reconnect to resume your chat.")}
    }}
    try child.run()
   } catch {fail(error.localizedDescription)}
  }
 }
 private func read(_ data:Data,handle:FileHandle) {
  guard !closing && !failed else {if data.isEmpty {handle.readabilityHandler=nil};return}
  do {
   if data.isEmpty {handle.readabilityHandler=nil;try framer.finish();fail("The chat backend disconnected. Reconnect to resume your chat.");return}
   for line in try framer.push(data) {
    let event=try JSONDecoder().decode(BridgeEvent.self,from:Data(line.utf8));onEvent?(event)
   }
  } catch {fail("Invalid or incomplete data from the chat backend. Reconnect to resume.");close()}
 }
 private func fail(_ message:String) {guard !failed else {return};failed=true;onEvent?(BridgeEvent(type:"fatal",message:message))}
 private func completeClose() {let completion=closeCompletion;closeCompletion=nil;completion?()}
 func send(_ command:[String:String]) {
  queue.async { [self] in
   guard !closing, let input else {if !closing {fail("The backend is not running. Reconnect to resume.")};return}
   do {var data=try JSONSerialization.data(withJSONObject:command);data.append(10);try input.write(contentsOf:data)}
   catch {fail("Could not send to the chat backend. Reconnect to resume.")}
  }
 }
 func close(completion: (@Sendable ()->Void)? = nil) {
  queue.async { [self] in
   guard !closing else {completion?();return};closing=true
   closeCompletion=completion
   if let input {try? input.write(contentsOf:Data("{\"type\":\"close\"}\n".utf8));try? input.close()};input=nil
   guard let child=process,child.isRunning else {completeClose();return}
   // The bridge waits for Codex to exit. Give that cleanup time, then signal its normal shutdown handler.
   queue.asyncAfter(deadline:.now()+3) {
    if child.isRunning {child.terminate()}
    self.queue.asyncAfter(deadline:.now()+2) {if child.isRunning {child.interrupt()};self.completeClose()}
   }
  }
 }
}
