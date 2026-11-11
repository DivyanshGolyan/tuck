import AppKit
import ObjectiveC
final class Delegate:NSObject,NSApplicationDelegate {
 var items:[NSStatusItem]=[]
 func dump(_ tag:String){print(tag);for item in items { print(item.button?.title ?? "?", "pos",item.value(forKey:"preferredPosition") ?? "?", "native",(item.value(forKey:"cgsItem") as? NSObject)?.value(forKey:"preferredPosition") ?? "?", "frame",item.button?.window?.frame ?? .zero) };fflush(stdout)}
 func applicationDidFinishLaunching(_ note:Notification){
  NSApp.setActivationPolicy(.accessory)
  for name in ["Alpha","Beta"] {let item=NSStatusBar.system.statusItem(withLength:28);item.autosaveName="TuckTest"+name;item.button?.title=String(name.prefix(1));item.button?.setAccessibilityIdentifier("TuckTest"+name);items.append(item)}
  DispatchQueue.main.asyncAfter(deadline:.now()+1){
   self.dump("BEFORE")
   let first=self.items[0];let second=self.items[1]
   guard let native=first.value(forKey:"cgsItem") as? NSObject,let position=second.value(forKey:"preferredPosition") as? NSNumber else{return}
   native.setValue(position.floatValue - 40,forKey:"preferredPosition")
   let selector=NSSelectorFromString("rebuildStatusBar")
   typealias Rebuild = @convention(c)(AnyObject,Selector)->Void
   let rebuild=unsafeBitCast(native.method(for:selector),to:Rebuild.self)
   rebuild(native,selector)
   DispatchQueue.main.asyncAfter(deadline:.now()+0.3){self.dump("AFTER")}
  }
 }
}
let app=NSApplication.shared;let d=Delegate();app.delegate=d;app.run()
