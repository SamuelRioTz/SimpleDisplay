#import "VirtualDisplayBridge.h"

@implementation VirtualDisplayWrapper {
    CGVirtualDisplay *_display;
}

+ (nullable instancetype)createWithName:(NSString *)name
                               vendorID:(uint32_t)vendorID
                              productID:(uint32_t)productID
                           serialNumber:(uint32_t)serialNumber
                      sizeInMillimeters:(CGSize)size
                          maxPixelsWide:(NSUInteger)maxW
                          maxPixelsHigh:(NSUInteger)maxH
                       terminationQueue:(dispatch_queue_t)queue
                     terminationHandler:(void (^)(void))handler
{
    // Runtime check: CGVirtualDisplay is a private API that may be removed in future macOS versions
    if (!NSClassFromString(@"CGVirtualDisplay") || !NSClassFromString(@"CGVirtualDisplayDescriptor")) {
        NSLog(@"VirtualDisplayWrapper: CGVirtualDisplay API not available on this system.");
        return nil;
    }

    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = name;
    desc.vendorID = vendorID;
    desc.productID = productID;
    desc.serialNumber = serialNumber;
    desc.sizeInMillimeters = size;
    desc.maxPixelsWide = maxW;
    desc.maxPixelsHigh = maxH;
    desc.dispatchQueue = queue;
    desc.terminationHandler = handler;

    CGVirtualDisplay *display = nil;
    @try {
        display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    } @catch (NSException *exception) {
        NSLog(@"VirtualDisplayWrapper: Failed to create virtual display: %@", exception.reason);
        return nil;
    }

    if (!display || display.displayID == 0) {
        return nil;
    }

    VirtualDisplayWrapper *wrapper = [[VirtualDisplayWrapper alloc] init];
    wrapper->_display = display;
    return wrapper;
}

- (CGDirectDisplayID)displayID {
    if (_display) {
        return _display.displayID;
    }
    return 0;
}

- (BOOL)applyWidth:(NSUInteger)width
            height:(NSUInteger)height
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI
{
    if (!_display) return NO;

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc]
        initWithWidth:width height:height refreshRate:refreshRate];

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;

    @try {
        return [_display applySettings:settings];
    } @catch (NSException *exception) {
        NSLog(@"VirtualDisplayWrapper: Failed to apply settings: %@", exception.reason);
        return NO;
    }
}

- (void)invalidate {
    _display = nil;
}

@end
