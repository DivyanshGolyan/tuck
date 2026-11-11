import AppKit
final class Delegate:NSObject,NSApplicationDelegate {
 var items:[NSStatusItem]=[]
 func applicationDidFinishLaunching(_ note:Notification) {
  NSApp.setActivationPolicy(.accessory)
  for name in ["Alpha","Beta"] {
   let item=NSStatusBar.system.statusItem(withLength:28)
   item.autosaveName="TuckTest"+name
   item.button?.title=String(name.prefix(1))
   item.button?.setAccessibilityIdentifier("TuckTest"+name)
   item.button?.setAccessibilityLabel("Tuck test "+name)
   item.button?.target=self;item.button?.action=#selector(click)
   items.append(item)
  }
 }
 @objc func click(){print("CLICK",NSApp.currentEvent?.modifierFlags.rawValue ?? 0);fflush(stdout)}
}
let app=NSApplication.shared;let d=Delegate();app.delegate=d;app.run()
