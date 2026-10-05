// Run on a logged-in macOS desktop; requires no Accessibility permission.
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>
#include "cocoa.h"

static nsfb_event_t next(void *window, enum nsfb_event_type_e type) {
    nsfb_event_t event;
    for (int i = 0; i < 64; ++i) {
        if (suzume_cocoa_poll(window, &event, 0) && event.type == type) return event;
    }
    assert(!"expected native input event");
    return (nsfb_event_t){0};
}
static NSEvent *key(NSEventType type, NSEventModifierFlags flags, NSString *text) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags
        timestamp:0 windowNumber:NSApp.keyWindow.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:0];
}
int main(void) {
    @autoreleasepool {
        void *window = suzume_cocoa_create(640, 480);
        assert(window);
        nsfb_event_t initial;
        for (int i = 0; i < 16; ++i) suzume_cocoa_poll(window, &initial, 0);
        NSWindow *native = NSApp.keyWindow;
        if (!native) for (NSWindow *candidate in NSApp.windows) {
            if ([candidate.title isEqualToString:@"Suzume"]) { native = candidate; break; }
        }
        NSView<NSTextInputClient> *view = (id)native.contentView;
        assert(view && view.acceptsFirstResponder);
        nsfb_event_t event;
        while (suzume_cocoa_poll(window, &event, 0)) {}

        // Verify BGRA conversion and top-left orientation through AppKit itself.
        const uint32_t pixels[] = { 0x00ff0000, 0x00ff0000, 0x000000ff, 0x000000ff };
        suzume_cocoa_present(window, (const unsigned char *)pixels, 2, 2, 8);
        NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
        NSColor *top = [[image colorAtX:image.pixelsWide / 2 y:image.pixelsHigh / 4]
            colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        NSColor *bottom = [[image colorAtX:image.pixelsWide / 2 y:3 * image.pixelsHigh / 4]
            colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        assert(top.redComponent > 0.9 && top.blueComponent < 0.1);
        assert(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1);

        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")];
        event = next(window, NSFB_EVENT_KEY_DOWN);
        assert(event.value.keycode == NSFB_KEY_a);
        unsigned char buffer[128];
        int count = suzume_cocoa_key_text(window, buffer, sizeof(buffer));
        assert(count == 1 && buffer[0] == 'a');
        [view keyUp:key(NSEventTypeKeyUp, 0, @"a")];
        assert(next(window, NSFB_EVENT_KEY_UP).value.keycode == NSFB_KEY_a);

        [view keyDown:key(NSEventTypeKeyDown, NSEventModifierFlagCommand, @"l")];
        assert(next(window, NSFB_EVENT_KEY_DOWN).value.keycode == NSFB_KEY_LCTRL);
        assert(next(window, NSFB_EVENT_KEY_DOWN).value.keycode == NSFB_KEY_l);
        assert(suzume_cocoa_key_text(window, buffer, sizeof(buffer)) == 0);
        [view keyUp:key(NSEventTypeKeyUp, 0, @"l")];
        assert(next(window, NSFB_EVENT_KEY_UP).value.keycode == NSFB_KEY_LCTRL);
        assert(next(window, NSFB_EVENT_KEY_UP).value.keycode == NSFB_KEY_l);

        // Candidate-window commits must reach the browser even outside keyDown.
        [view setMarkedText:@"にほん" selectedRange:NSMakeRange(0, 3) replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(view.hasMarkedText);
        [view insertText:@"日本" replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(!view.hasMarkedText);
        assert(next(window, NSFB_EVENT_KEY_DOWN).value.keycode == NSFB_KEY_UNKNOWN);
        count = suzume_cocoa_key_text(window, buffer, sizeof(buffer));
        assert(count == 6 && memcmp(buffer, "日本", 6) == 0);

        const char *families[] = { "sans-serif", "serif", "monospace" };
        for (unsigned i = 0; i < 3; ++i) {
            unsigned char path[4096];
            int length = suzume_cocoa_font_path((const unsigned char *)families[i],
                (int)strlen(families[i]), path, sizeof(path) - 1);
            assert(length > 0);
            path[length] = 0;
            assert([NSFileManager.defaultManager fileExistsAtPath:[NSString stringWithUTF8String:(char *)path]]);
        }

        // Preserve the user's clipboard while testing the bridge.
        NSMutableArray<NSPasteboardItem *> *previous = [NSMutableArray new];
        for (NSPasteboardItem *old in NSPasteboard.generalPasteboard.pasteboardItems) {
            NSPasteboardItem *saved = [NSPasteboardItem new];
            for (NSPasteboardType type in old.types) {
                NSData *data = [old dataForType:type];
                if (data) [saved setData:data forType:type];
            }
            [previous addObject:saved];
        }
        suzume_cocoa_copy((const unsigned char *)"hello 日本", 12);
        assert(suzume_cocoa_clipboard(buffer, sizeof(buffer)) == 12);
        assert(memcmp(buffer, "hello 日本", 12) == 0);
        [NSPasteboard.generalPasteboard clearContents];
        if (previous.count) [NSPasteboard.generalPasteboard writeObjects:previous];

        [native setContentSize:NSMakeSize(720, 520)];
        event = next(window, NSFB_EVENT_RESIZE);
        assert(event.value.resize.w == 720 && event.value.resize.h == 520);
        assert([NSApp.delegate applicationShouldTerminate:NSApp] == NSTerminateCancel);
        assert(next(window, NSFB_EVENT_CONTROL).value.controlcode == NSFB_CONTROL_QUIT);
        [native performClose:nil];
        assert(next(window, NSFB_EVENT_CONTROL).value.controlcode == NSFB_CONTROL_QUIT);
        suzume_cocoa_destroy(window);
        puts("Cocoa smoke tests passed: presentation, input, Command, IME, fonts, clipboard, resize, quit");
    }
    return 0;
}
