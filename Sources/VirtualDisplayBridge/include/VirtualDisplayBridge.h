#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// CGVirtualDisplayMode - one resolution mode for a virtual display
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@end

// CGVirtualDisplaySettings - applied to an existing virtual display
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) NSUInteger hiDPI;
@property (nonatomic) NSUInteger rotation;
@end

// CGVirtualDisplayDescriptor - configuration for creating a new virtual display
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);
@end

// CGVirtualDisplay - the live virtual display object
@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// VirtualDisplayWrapper - Swift-friendly wrapper
@interface VirtualDisplayWrapper : NSObject

+ (nullable instancetype)createWithName:(NSString *)name
                               vendorID:(uint32_t)vendorID
                              productID:(uint32_t)productID
                           serialNumber:(uint32_t)serialNumber
                      sizeInMillimeters:(CGSize)size
                          maxPixelsWide:(NSUInteger)maxW
                          maxPixelsHigh:(NSUInteger)maxH
                       terminationQueue:(dispatch_queue_t)queue
                     terminationHandler:(void (^)(void))handler;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

- (BOOL)applyWidth:(NSUInteger)width
            height:(NSUInteger)height
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
