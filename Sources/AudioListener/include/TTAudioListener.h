#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one native block. Core Audio requires the same listener block for removal.
@interface TTAudioListener : NSObject
- (instancetype)initWithHandler:(dispatch_block_t)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (OSStatus)addForObject:(AudioObjectID)object address:(AudioObjectPropertyAddress)address queue:(dispatch_queue_t)queue;
- (OSStatus)removeForObject:(AudioObjectID)object address:(AudioObjectPropertyAddress)address queue:(dispatch_queue_t)queue;
@end

NS_ASSUME_NONNULL_END
