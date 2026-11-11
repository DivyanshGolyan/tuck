// Isolated fixture-only diagnostic. Not run by its author.
// Build: clang -fobjc-arc -framework AppKit -framework CoreGraphics /tmp/tuck-direct-probe.m -o /tmp/tuck-direct-probe
// Set: /tmp/tuck-direct-probe set WINDOW_ID INDEX
// Reset explicit fixture windows: /tmp/tuck-direct-probe reset WINDOW_ID [WINDOW_ID ...]
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <limits.h>
static void fail(NSString *s) { fprintf(stderr,"%s\n",s.UTF8String); exit(2); }
static long long number(const char *s, long long lo, long long hi) {
    char *end = NULL; errno = 0; long long v = strtoll(s,&end,10);
    if (errno || !s[0] || *end || v<lo || v>hi) fail(@"Invalid numeric argument"); return v;
}
static NSDictionary *validate(uint32_t wid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    for (NSDictionary *w in windows) if ([w[(__bridge id)kCGWindowNumber] unsignedIntValue] == wid) {
        pid_t pid = [w[(__bridge id)kCGWindowOwnerPID] intValue];
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (![app.bundleIdentifier isEqual:@"local.tuck.fixture"] || ![app.bundleURL.path isEqual:@"/tmp/TuckFixture.app"])
            fail(@"REFUSED: window owner is not /tmp/TuckFixture.app (local.tuck.fixture)");
        return w;
    }
    fail(@"REFUSED: explicit window ID is not currently present"); return nil;
}
int main(int argc,const char **argv) { @autoreleasepool {
    BOOL set = argc == 4 && strcmp(argv[1],"set")==0;
    BOOL reset = argc >= 3 && strcmp(argv[1],"reset")==0;
    if (!set && !reset) fail(@"Usage: probe set WINDOW_ID INDEX | probe reset WINDOW_ID [...]");
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    if (set) [ids addObject:@(number(argv[2],1,UINT32_MAX))];
    else for(int i=2;i<argc;i++) [ids addObject:@(number(argv[i],1,UINT32_MAX))];
    int32_t index = set ? (int32_t)number(argv[3],0,INT_MAX) : 0;
    for (NSNumber *n in ids) fprintf(stderr,"Before %s\n",[validate(n.unsignedIntValue) description].UTF8String);
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
    if (!h) fail(@"Cannot load SkyLight");
    int (*mainCID)(void) = dlsym(h,"CGSMainConnectionID");
    CFTypeRef (*create)(int) = dlsym(h,"SLSTransactionCreate");
    void (*commit)(CFTypeRef,int) = dlsym(h,"SLSTransactionCommit");
    void (*layout)(CFTypeRef,uint32_t,int32_t) = dlsym(h,"SLSTransactionSystemStatusBarSetLayoutIndex");
    void (*resetLayout)(CFTypeRef,CFArrayRef) = dlsym(h,"SLSTransactionSystemStatusBarResetLayout");
    if(!mainCID || !create || !commit || !layout || !resetLayout) fail(@"Missing required symbols");
    (void)[NSApplication sharedApplication];
    int cid=mainCID(); if(cid<=0) fail(@"Invalid main connection");
    CFTypeRef tx=create(cid); if(!tx) fail(@"Transaction allocation failed");
    // Recheck each owner immediately before queueing; never enumerate other targets.
    for(NSNumber *n in ids) (void)validate(n.unsignedIntValue);
    if(set) layout(tx,ids[0].unsignedIntValue,index);
    else resetLayout(tx,(__bridge CFArrayRef)ids);
    commit(tx,1); CFRelease(tx);
    fprintf(stderr,"Commit returned (void; not proof of per-operation success)\n");
    [NSThread sleepForTimeInterval:0.4];
    for(NSNumber *n in ids) fprintf(stderr,"After %s\n",[validate(n.unsignedIntValue) description].UTF8String);
    return 0;
} }
