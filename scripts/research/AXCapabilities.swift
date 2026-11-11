import AppKit
import ApplicationServices
func value(_ e:AXUIElement,_ name:String)->CFTypeRef?{var v:CFTypeRef?;guard AXUIElementCopyAttributeValue(e,name as CFString,&v) == .success else{return nil};return v}
let pid=Int32(CommandLine.arguments[1])!;guard NSRunningApplication(processIdentifier:pid)?.bundleIdentifier == "local.tuck.fixture" else{exit(1)}
let app=AXUIElementCreateApplication(pid);let bar=value(app,"AXExtrasMenuBar") as! AXUIElement
for item in value(bar,"AXChildren") as! [AXUIElement] {var names:CFArray?;AXUIElementCopyAttributeNames(item,&names);print("ITEM",value(item,"AXIdentifier") ?? "?" as CFString)
 for n in names as? [String] ?? []{var settable:DarwinBoolean=false;let status=AXUIElementIsAttributeSettable(item,n as CFString,&settable);print(n,"settable",settable.boolValue,"status",status.rawValue)}
 var actions:CFArray?;AXUIElementCopyActionNames(item,&actions);print("actions",actions ?? [] as CFArray)
}
