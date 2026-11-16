import Foundation
import SwiftUI

struct AboutInfo:Equatable {
 let name:String
 let versionLine:String
 let buildDateLine:String
 static func parseBuildDate(_ raw:String)->Date? {
  let formatter=ISO8601DateFormatter()
  formatter.formatOptions=[.withInternetDateTime]
  return formatter.date(from:raw.trimmingCharacters(in:.whitespacesAndNewlines))
 }
 static func formatBuildDate(_ date:Date)->String {
  let formatter=DateFormatter()
  formatter.locale=Locale(identifier:"en_US_POSIX")
  formatter.timeZone=TimeZone(secondsFromGMT:0)
  formatter.dateFormat="MMM d, yyyy, h:mm a"
  return formatter.string(from:date)+" UTC"
 }
 static func make(name:String?,version:String?,build:String?,buildDate:String?)->AboutInfo {
  func cleaned(_ value:String?)->String? {
   let trimmed=value?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
   return trimmed.isEmpty ? nil : trimmed
  }
  let resolvedName=cleaned(name) ?? "SpeedChat"
  let versionText=cleaned(version)
  let buildText=cleaned(build)
  let versionLine:String
  if let versionText,let buildText {versionLine="Version \(versionText) (\(buildText))"}
  else if let versionText {versionLine="Version \(versionText)"}
  else {versionLine="Development"}
  let buildDateLine:String
  if let raw=cleaned(buildDate),let date=parseBuildDate(raw) {buildDateLine="Built \(formatBuildDate(date))"}
  else if cleaned(buildDate) != nil {buildDateLine="Build date unavailable"}
  else {buildDateLine="Development build"}
  return AboutInfo(name:resolvedName,versionLine:versionLine,buildDateLine:buildDateLine)
 }
 static func current(bundle:Bundle = .main)->AboutInfo {
  func string(_ key:String)->String? {bundle.object(forInfoDictionaryKey:key) as? String}
  return make(name:string("CFBundleDisplayName") ?? string("CFBundleName"),version:string("CFBundleShortVersionString"),build:string("CFBundleVersion"),buildDate:string("SpeedChatBuildDate"))
 }
}
struct AboutView:View {
 let info:AboutInfo
 var body:some View {
  VStack(spacing:6) {
   Text(info.name).font(.title2.weight(.semibold))
   Text(info.versionLine).textSelection(.enabled)
   Text(info.buildDateLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
  }
  .multilineTextAlignment(.center)
  .padding(.horizontal,24)
  .padding(.vertical,20)
  .frame(width:300)
  .fixedSize(horizontal:false,vertical:true)
 }
}
