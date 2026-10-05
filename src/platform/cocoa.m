// Native AppKit presentation/input for the existing libnsfb software renderer.
// All entry points and AppKit callbacks run on the browser's main thread.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include "cocoa.h"

@interface SuzumeInput : NSObject
@property(nonatomic) nsfb_event_t event;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) BOOL filtered;
@end
@implementation SuzumeInput
@end

@interface SuzumeView : NSView <NSTextInputClient>
@property(nonatomic) const unsigned char *pixels;
@property(nonatomic) int pixelWidth, pixelHeight, stride;
@property(nonatomic, strong) NSMutableArray<SuzumeInput *> *events;
@property(nonatomic, strong) NSMutableAttributedString *marked;
@property(nonatomic, copy) NSString *committed;
@property(nonatomic) NSEventModifierFlags modifiers;
@property(nonatomic) double wheelRemainder;
@property(nonatomic) BOOL handlingKey;
- (void)enqueue:(nsfb_event_t)event text:(NSString *)text filtered:(BOOL)filtered;
@end

@implementation SuzumeView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)enqueue:(nsfb_event_t)event text:(NSString *)text filtered:(BOOL)filtered {
    // Coalesce motion/resize bursts without dropping key transitions or text.
    SuzumeInput *last = self.events.lastObject;
    if (last && last.event.type == event.type &&
        (event.type == NSFB_EVENT_MOVE_ABSOLUTE || event.type == NSFB_EVENT_RESIZE)) {
        last.event = event;
        return;
    }
    SuzumeInput *input = [SuzumeInput new];
    input.event = event;
    input.text = text;
    input.filtered = filtered;
    [self.events addObject:input];
}
- (void)drawRect:(NSRect)rect {
    [[NSColor whiteColor] setFill];
    NSRectFill(rect);
    if (!self.pixels) return;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, self.pixels,
        (size_t)self.stride * self.pixelHeight, NULL);
    CGImageRef image = CGImageCreate(self.pixelWidth, self.pixelHeight, 8, 32,
        self.stride, space, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, self.bounds, image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
}
- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    nsfb_event_t e = { .type = NSFB_EVENT_MOVE_ABSOLUTE };
    e.value.vector.x = (int)p.x;
    e.value.vector.y = (int)p.y;
    [self enqueue:e text:nil filtered:NO];
}
- (void)mouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseButton:(NSEvent *)event down:(BOOL)down {
    [self mouseMoved:event];
    [self.window makeFirstResponder:self];
    nsfb_event_t e = { .type = down ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP };
    e.value.keycode = event.buttonNumber == 0 ? NSFB_KEY_MOUSE_1 :
        event.buttonNumber == 1 ? NSFB_KEY_MOUSE_3 : NSFB_KEY_MOUSE_2;
    [self enqueue:e text:nil filtered:NO];
}
- (void)mouseDown:(NSEvent *)e { [self mouseButton:e down:YES]; }
- (void)mouseUp:(NSEvent *)e { [self mouseButton:e down:NO]; }
- (void)rightMouseDown:(NSEvent *)e { [self mouseButton:e down:YES]; }
- (void)rightMouseUp:(NSEvent *)e { [self mouseButton:e down:NO]; }
- (void)otherMouseDown:(NSEvent *)e { [self mouseButton:e down:YES]; }
- (void)otherMouseUp:(NSEvent *)e { [self mouseButton:e down:NO]; }
- (void)scrollWheel:(NSEvent *)event {
    [self mouseMoved:event];
    self.wheelRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 12.0 : 1.0);
    int ticks = (int)self.wheelRemainder;
    self.wheelRemainder -= ticks;
    // Bound a single burst so an extreme device delta cannot flood the queue.
    ticks = MAX(-20, MIN(20, ticks));
    for (int i = 0; i < abs(ticks); ++i) {
        nsfb_event_t e = { .type = NSFB_EVENT_KEY_DOWN };
        e.value.keycode = ticks > 0 ? NSFB_KEY_MOUSE_4 : NSFB_KEY_MOUSE_5;
        [self enqueue:e text:nil filtered:NO];
    }
}
- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags next = event.modifierFlags;
    const NSEventModifierFlags flags[] = { NSEventModifierFlagShift,
        NSEventModifierFlagControl | NSEventModifierFlagCommand, NSEventModifierFlagOption };
    const enum nsfb_key_code_e keys[] = { NSFB_KEY_LSHIFT, NSFB_KEY_LCTRL, NSFB_KEY_LALT };
    for (int i = 0; i < 3; ++i) {
        BOOL before = (self.modifiers & flags[i]) != 0, after = (next & flags[i]) != 0;
        if (before == after) continue;
        nsfb_event_t e = { .type = after ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP };
        e.value.keycode = keys[i];
        [self enqueue:e text:nil filtered:NO];
    }
    self.modifiers = next;
}
static enum nsfb_key_code_e keyCode(NSEvent *event) {
    NSString *s = event.charactersIgnoringModifiers;
    if (!s.length) return NSFB_KEY_UNKNOWN;
    unichar ch = [s characterAtIndex:0];
    switch (ch) {
        case NSDeleteCharacter: return NSFB_KEY_BACKSPACE;
        case NSDeleteFunctionKey: return NSFB_KEY_DELETE;
        case NSLeftArrowFunctionKey: return NSFB_KEY_LEFT;
        case NSRightArrowFunctionKey: return NSFB_KEY_RIGHT;
        case NSUpArrowFunctionKey: return NSFB_KEY_UP;
        case NSDownArrowFunctionKey: return NSFB_KEY_DOWN;
        case NSHomeFunctionKey: return NSFB_KEY_HOME;
        case NSEndFunctionKey: return NSFB_KEY_END;
        case NSPageUpFunctionKey: return NSFB_KEY_PAGEUP;
        case NSPageDownFunctionKey: return NSFB_KEY_PAGEDOWN;
        case NSF5FunctionKey: return NSFB_KEY_F5;
        case NSBackTabCharacter: return NSFB_KEY_TAB;
        default:
            if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
            return ch < 128 ? (enum nsfb_key_code_e)ch : NSFB_KEY_UNKNOWN;
    }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        if ([event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"h"]) return NO;
        [self keyDown:event];
        return YES;
    }
    return NO;
}
- (void)keyDown:(NSEvent *)event {
    [self flagsChanged:event];
    self.committed = nil;
    BOOL command = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    BOOL wasMarked = self.hasMarkedText;
    self.handlingKey = YES;
    if (!command) [self interpretKeyEvents:@[event]];
    self.handlingKey = NO;
    nsfb_event_t e = { .type = NSFB_EVENT_KEY_DOWN };
    e.value.keycode = keyCode(event);
    [self enqueue:e text:self.committed filtered:(!command && (wasMarked || self.hasMarkedText))];
    self.committed = nil;
}
- (void)keyUp:(NSEvent *)event {
    [self flagsChanged:event];
    nsfb_event_t e = { .type = NSFB_EVENT_KEY_UP };
    e.value.keycode = keyCode(event);
    [self enqueue:e text:nil filtered:NO];
}
- (void)insertText:(id)text replacementRange:(NSRange)range {
    (void)range;
    NSString *s = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
    if (self.handlingKey) {
        self.committed = [(self.committed ?: @"") stringByAppendingString:s];
    } else {
        // IMEs may commit from their candidate window rather than keyDown.
        nsfb_event_t e = { .type = NSFB_EVENT_KEY_DOWN };
        e.value.keycode = NSFB_KEY_UNKNOWN;
        [self enqueue:e text:s filtered:NO];
    }
    [self unmarkText];
}
- (void)setMarkedText:(id)text selectedRange:(NSRange)selection replacementRange:(NSRange)range {
    (void)selection; (void)range;
    self.marked = [text isKindOfClass:NSAttributedString.class] ?
        [text mutableCopy] : [[NSMutableAttributedString alloc] initWithString:text];
}
- (void)unmarkText { self.marked = [[NSMutableAttributedString alloc] initWithString:@""]; }
- (BOOL)hasMarkedText { return self.marked.length > 0; }
- (NSRange)markedRange { return self.hasMarkedText ? NSMakeRange(0, self.marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(0, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    if (actual) *actual = NSMakeRange(NSNotFound, 0);
    return nil;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return 0; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    if (actual) *actual = range;
    NSRect anchor = NSMakeRect(12, 32, 1, 20);
    return [self.window convertRectToScreen:[self convertRect:anchor toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector { (void)selector; }
@end

@interface SuzumeWindow : NSObject <NSWindowDelegate, NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) SuzumeView *view;
@property(nonatomic, copy) NSString *lastText;
@property(nonatomic) BOOL lastFiltered;
@end
@implementation SuzumeWindow
- (void)requestQuit:(id)sender {
    nsfb_event_t e = { .type = NSFB_EVENT_CONTROL };
    e.value.controlcode = NSFB_CONTROL_QUIT;
    [self.view enqueue:e text:nil filtered:NO];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self requestQuit:sender];
    return NSTerminateCancel; // Main loop saves state and then exits normally.
}
- (void)shortcut:(NSMenuItem *)sender {
    nsfb_event_t e = { .type = NSFB_EVENT_KEY_DOWN };
    e.value.keycode = NSFB_KEY_LCTRL;
    [self.view enqueue:e text:nil filtered:NO];
    e.value.keycode = (enum nsfb_key_code_e)[sender.representedObject intValue];
    [self.view enqueue:e text:nil filtered:NO];
    e.type = NSFB_EVENT_KEY_UP;
    [self.view enqueue:e text:nil filtered:NO];
    e.value.keycode = NSFB_KEY_LCTRL;
    [self.view enqueue:e text:nil filtered:NO];
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    nsfb_event_t e = { .type = NSFB_EVENT_CONTROL };
    e.value.controlcode = NSFB_CONTROL_QUIT;
    [self.view enqueue:e text:nil filtered:NO];
    return NO; // The browser owns lifetime and saves its session before closing.
}
- (void)windowDidResize:(NSNotification *)notification {
    self.view.pixels = NULL; // RAM buffer may be reallocated by the resize handler.
    nsfb_event_t e = { .type = NSFB_EVENT_RESIZE };
    e.value.resize.w = MAX(320, (int)self.view.bounds.size.width);
    e.value.resize.h = MAX(240, (int)self.view.bounds.size.height);
    [self.view enqueue:e text:nil filtered:NO];
}
- (void)windowDidResignKey:(NSNotification *)notification {
    // Release held modifiers when switching applications.
    const enum nsfb_key_code_e keys[] = { NSFB_KEY_LSHIFT, NSFB_KEY_LCTRL, NSFB_KEY_LALT };
    for (int i = 0; i < 3; ++i) {
        nsfb_event_t e = { .type = NSFB_EVENT_KEY_UP };
        e.value.keycode = keys[i];
        [self.view enqueue:e text:nil filtered:NO];
    }
    self.view.modifiers = 0;
}
@end

void *suzume_cocoa_create(int width, int height) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        SuzumeWindow *state = [SuzumeWindow new];
        state.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        state.window.title = @"Suzume";
        state.window.releasedWhenClosed = NO;
        state.window.contentMinSize = NSMakeSize(320, 240);
        state.view = [[SuzumeView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
        state.view.events = [NSMutableArray new];
        [state.view unmarkText];
        state.window.contentView = state.view;
        state.window.delegate = state;
        NSApp.delegate = state;
        NSMenu *menu = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Suzume"];
        [appMenu addItemWithTitle:@"About Suzume" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:NSMenuItem.separatorItem];
        [appMenu addItemWithTitle:@"Hide Suzume" action:@selector(hide:) keyEquivalent:@"h"];
        NSMenuItem *quit = [appMenu addItemWithTitle:@"Quit Suzume" action:@selector(requestQuit:) keyEquivalent:@"q"];
        quit.target = state;
        appItem.submenu = appMenu;
        [menu addItem:appItem];
        const struct { const char *title; int key; } shortcuts[] = {
            { "New Tab", NSFB_KEY_t }, { "Close Tab", NSFB_KEY_w },
            { "Open Location", NSFB_KEY_l }, { "Reload", NSFB_KEY_r },
            { "Find", NSFB_KEY_f }, { "Select All", NSFB_KEY_a },
            { "Copy", NSFB_KEY_c }, { "Paste", NSFB_KEY_v }
        };
        NSMenuItem *browserItem = [[NSMenuItem alloc] initWithTitle:@"Browser" action:nil keyEquivalent:@""];
        NSMenu *browserMenu = [[NSMenu alloc] initWithTitle:@"Browser"];
        for (unsigned i = 0; i < sizeof(shortcuts) / sizeof(shortcuts[0]); ++i) {
            NSString *equivalent = [NSString stringWithFormat:@"%c", shortcuts[i].key];
            NSMenuItem *item = [browserMenu addItemWithTitle:[NSString stringWithUTF8String:shortcuts[i].title]
                action:@selector(shortcut:) keyEquivalent:equivalent];
            item.target = state;
            item.representedObject = @(shortcuts[i].key);
        }
        browserItem.submenu = browserMenu;
        [menu addItem:browserItem];
        NSApp.mainMenu = menu;
        [state.window center];
        [state.window makeKeyAndOrderFront:nil];
        [state.window makeFirstResponder:state.view];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];
        return (void *)CFBridgingRetain(state);
    }
}
void suzume_cocoa_destroy(void *opaque) {
    @autoreleasepool {
        SuzumeWindow *state = CFBridgingRelease(opaque);
        state.view.pixels = NULL;
        state.window.delegate = nil;
        NSApp.delegate = nil;
        NSApp.mainMenu = nil;
        [state.window close];
    }
}
void suzume_cocoa_present(void *opaque, const unsigned char *pixels, int width, int height, int stride) {
    @autoreleasepool {
        SuzumeWindow *state = (__bridge SuzumeWindow *)opaque;
        state.view.pixels = pixels;
        state.view.pixelWidth = width;
        state.view.pixelHeight = height;
        state.view.stride = stride;
        [state.view setNeedsDisplay:YES];
        [state.view displayIfNeeded];
    }
}
bool suzume_cocoa_poll(void *opaque, nsfb_event_t *out, int timeout) {
    @autoreleasepool {
        SuzumeWindow *state = (__bridge SuzumeWindow *)opaque;
        NSDate *until = timeout < 0 ? NSDate.distantFuture : [NSDate dateWithTimeIntervalSinceNow:timeout / 1000.0];
        // Drain already-translated input before waiting for another AppKit event.
        while (!state.view.events.count) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!event) return false;
            [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
        SuzumeInput *input = state.view.events.firstObject;
        *out = input.event;
        state.lastText = input.text;
        state.lastFiltered = input.filtered;
        [state.view.events removeObjectAtIndex:0];
        return true;
    }
}
int suzume_cocoa_key_text(void *opaque, unsigned char *buffer, int capacity) {
    @autoreleasepool {
        SuzumeWindow *state = (__bridge SuzumeWindow *)opaque;
        NSData *data = [state.lastText dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length && data.length <= (NSUInteger)capacity) {
            memcpy(buffer, data.bytes, data.length);
            state.lastText = nil;
            return (int)data.length;
        }
        return state.lastFiltered ? -1 : 0;
    }
}
bool suzume_cocoa_composing(void *opaque) {
    return ((__bridge SuzumeWindow *)opaque).view.hasMarkedText;
}
void suzume_cocoa_cursor(int shape) {
    @autoreleasepool {
        NSCursor *cursor = shape == 1 ? NSCursor.pointingHandCursor : shape == 2 ? NSCursor.IBeamCursor : NSCursor.arrowCursor;
        [cursor set];
    }
}
int suzume_cocoa_font_path(const unsigned char *family, int length, unsigned char *buffer, int capacity) {
    @autoreleasepool {
        NSString *name = [[NSString alloc] initWithBytes:family length:length encoding:NSUTF8StringEncoding];
        if (!name) return 0;
        NSString *lower = name.lowercaseString;
        if ([lower isEqualToString:@"sans-serif"] || [lower isEqualToString:@"system-ui"] ||
            [lower isEqualToString:@"ui-sans-serif"]) name = @"Helvetica";
        else if ([lower isEqualToString:@"serif"] || [lower isEqualToString:@"ui-serif"]) name = @"Times";
        else if ([lower isEqualToString:@"monospace"] || [lower isEqualToString:@"ui-monospace"]) name = @"Menlo";
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, 14, NULL);
        if (!font) return 0;
        NSURL *url = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
        CFRelease(font);
        NSData *data = [url.path dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length || data.length > (NSUInteger)capacity) return 0;
        memcpy(buffer, data.bytes, data.length);
        return (int)data.length;
    }
}
void suzume_cocoa_copy(const unsigned char *text, int length) {
    @autoreleasepool {
        NSString *string = [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
        if (!string) return;
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:string forType:NSPasteboardTypeString];
    }
}
int suzume_cocoa_clipboard(unsigned char *buffer, int capacity) {
    @autoreleasepool {
        NSData *data = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
            dataUsingEncoding:NSUTF8StringEncoding];
        if (buffer && data.length <= (NSUInteger)capacity) memcpy(buffer, data.bytes, data.length);
        return (int)MIN(data.length, INT_MAX);
    }
}
