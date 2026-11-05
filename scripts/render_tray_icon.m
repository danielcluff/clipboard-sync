// Developer asset renderer. Ordinary app builds use the checked-in PDF and ICOs.
#import <AppKit/AppKit.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 1;
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!image)
            return 2;
        int sizes[] = {16, 20, 24, 32, 40, 48, 64, 256};
        for (int white = 0; white <= 1; white++) {
            for (int i = 0; i < 8; i++) {
                int size = sizes[i];
                NSBitmapImageRep *bitmap =
                    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                            pixelsWide:size
                                                            pixelsHigh:size
                                                         bitsPerSample:8
                                                       samplesPerPixel:4
                                                              hasAlpha:YES
                                                              isPlanar:NO
                                                        colorSpaceName:NSDeviceRGBColorSpace
                                                           bytesPerRow:0
                                                          bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext
                    setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
                NSRect rect = NSMakeRect(0, 0, size, size);
                [NSColor.clearColor setFill];
                NSRectFillUsingOperation(rect, NSCompositingOperationCopy);
                [image drawInRect:rect
                         fromRect:NSZeroRect
                        operation:NSCompositingOperationSourceOver
                         fraction:1];
                [(white ? NSColor.whiteColor : NSColor.blackColor) setFill];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
                [NSGraphicsContext restoreGraphicsState];
                NSString *name = [NSString
                    stringWithFormat:@"%s/%s-%d.png", argv[2], white ? "white" : "black", size];
                if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG
                                           properties:@{}] writeToFile:name atomically:YES])
                    return 3;
            }
        }
        // Application artwork uses the same glyph on a neutral tile for Finder.
        int appSizes[] = {16, 32, 64, 128, 256, 512, 1024};
        for (int i = 0; i < 7; i++) {
            int size = appSizes[i];
            CGFloat scale = size / 1024.0;
            NSBitmapImageRep *bitmap =
                [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                        pixelsWide:size
                                                        pixelsHigh:size
                                                     bitsPerSample:8
                                                   samplesPerPixel:4
                                                          hasAlpha:YES
                                                          isPlanar:NO
                                                    colorSpaceName:NSDeviceRGBColorSpace
                                                       bytesPerRow:0
                                                      bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext
                setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
            [NSColor.clearColor setFill];
            NSRectFillUsingOperation(NSMakeRect(0, 0, size, size), NSCompositingOperationCopy);
            [NSGraphicsContext saveGraphicsState];
            NSShadow *shadow = [NSShadow new];
            shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.16];
            shadow.shadowOffset = NSMakeSize(0, -8 * scale);
            shadow.shadowBlurRadius = 20 * scale;
            [shadow set];
            [[NSColor colorWithWhite:0.98 alpha:1] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100 * scale, 100 * scale,
                                                                824 * scale, 824 * scale)
                                             xRadius:180 * scale
                                             yRadius:180 * scale] fill];
            [NSGraphicsContext restoreGraphicsState];
            [image drawInRect:NSMakeRect(208 * scale, 208 * scale, 608 * scale, 608 * scale)];
            [NSGraphicsContext restoreGraphicsState];
            NSString *name = [NSString stringWithFormat:@"%s/app-%d.png", argv[2], size];
            if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}] writeToFile:name atomically:YES])
                return 5;
        }
        // Preview the actual vector at presentation and tray sizes on light/dark surfaces.
        NSBitmapImageRep *preview =
            [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                    pixelsWide:720
                                                    pixelsHigh:260
                                                 bitsPerSample:8
                                               samplesPerPixel:4
                                                      hasAlpha:YES
                                                      isPlanar:NO
                                                colorSpaceName:NSDeviceRGBColorSpace
                                                   bytesPerRow:0
                                                  bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext
            setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:preview]];
        for (int dark = 0; dark < 2; dark++) {
            [(dark ? [NSColor colorWithWhite:0.10 alpha:1]
                   : [NSColor colorWithWhite:0.96 alpha:1]) setFill];
            NSRectFill(NSMakeRect(dark * 360, 0, 360, 260));
            NSColor *ink = dark ? NSColor.whiteColor : NSColor.blackColor;
            int previewSizes[] = {120, 16, 24, 32};
            int x[] = {120, 120, 167, 222};
            int y[] = {90, 40, 36, 32};
            for (int i = 0; i < 4; i++) {
                NSImage *tinted =
                    [NSImage imageWithSize:NSMakeSize(24, 24)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect rect) {
                              [image drawInRect:rect
                                       fromRect:NSZeroRect
                                      operation:NSCompositingOperationSourceOver
                                       fraction:1];
                              [ink setFill];
                              NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
                              return YES;
                            }];
                [tinted drawInRect:NSMakeRect(dark * 360 + x[i], y[i], previewSizes[i],
                                              previewSizes[i])];
            }
        }
        [NSGraphicsContext restoreGraphicsState];
        return [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                   writeToFile:[NSString stringWithFormat:@"%s/preview.png", argv[2]]
                    atomically:YES]
                   ? 0
                   : 4;
    }
}
