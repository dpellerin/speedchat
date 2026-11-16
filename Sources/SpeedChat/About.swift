import Foundation
import SwiftUI

struct AboutInfo:Equatable {
 let name:String
 let versionLine:String
 let buildDateLine:String
 let copyright:String?
 static func parseBuildDate(_ raw:String)->Date? {
  let formatter=ISO8601DateFormatter()
  formatter.formatOptions=[.withInternetDateTime]
  return formatter.date(from:raw.trimmingCharacters(in:.whitespacesAndNewlines))
 }
 static func formatBuildDate(_ date:Date,timeZone:TimeZone = .current,locale:Locale = .current)->String {
  let formatter=DateFormatter()
  formatter.locale=locale
  formatter.timeZone=timeZone
  formatter.dateStyle=.medium
  formatter.timeStyle=.short
  let formatted=formatter.string(from:date)
  let zone=timeZone.abbreviation(for:date).flatMap{$0.isEmpty ? nil : $0} ?? timeZone.identifier
  if formatted.hasSuffix(" "+zone) {return formatted}
  return formatted+" "+zone
 }
 static func make(name:String?,version:String?,build:String?,buildDate:String?,copyright:String?=nil,timeZone:TimeZone = .current,locale:Locale = .current)->AboutInfo {
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
  if let raw=cleaned(buildDate),let date=parseBuildDate(raw) {buildDateLine="Built \(formatBuildDate(date,timeZone:timeZone,locale:locale))"}
  else if cleaned(buildDate) != nil {buildDateLine="Build date unavailable"}
  else {buildDateLine="Development build"}
  return AboutInfo(name:resolvedName,versionLine:versionLine,buildDateLine:buildDateLine,copyright:cleaned(copyright))
 }
 static func current(bundle:Bundle = .main,timeZone:TimeZone = .current,locale:Locale = .current)->AboutInfo {
  func string(_ key:String)->String? {bundle.object(forInfoDictionaryKey:key) as? String}
  return make(name:string("CFBundleDisplayName") ?? string("CFBundleName"),version:string("CFBundleShortVersionString"),build:string("CFBundleVersion"),buildDate:string("SpeedChatBuildDate"),copyright:string("NSHumanReadableCopyright"),timeZone:timeZone,locale:locale)
 }
}
struct AboutView:View {
 let info:AboutInfo
 var body:some View {
  VStack(spacing:6) {
   Text(info.name).font(.title2.weight(.semibold))
   Text(info.versionLine).textSelection(.enabled)
   Text(info.buildDateLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
   if let copyright=info.copyright {
    Text(copyright).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
   }
  }
  .multilineTextAlignment(.center)
  .padding(.horizontal,24)
  .padding(.vertical,20)
  .frame(width:340)
  .fixedSize(horizontal:false,vertical:true)
 }
}
