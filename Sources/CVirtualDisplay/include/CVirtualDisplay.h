// HACK: private API. CoreGraphics' virtual display classes are in the framework
// but not in its headers. Rejig uses them for one thing: the agent screen, a
// display with no monitor where automated windows can sit out of the way.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) NSUInteger maxPixelsWide;
@property(nonatomic) NSUInteger maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) NSUInteger productID;
@property(nonatomic) NSUInteger vendorID;
@property(nonatomic) NSUInteger serialNum;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) NSUInteger hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@end
