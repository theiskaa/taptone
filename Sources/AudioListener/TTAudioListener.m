#import "TTAudioListener.h"

@implementation TTAudioListener {
    AudioObjectPropertyListenerBlock _block;
}

- (instancetype)initWithHandler:(dispatch_block_t)handler {
    self = [super init];
    if (self != nil) {
        _block = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
            handler();
        } copy];
    }
    return self;
}

- (OSStatus)addForObject:(AudioObjectID)object address:(AudioObjectPropertyAddress)address queue:(dispatch_queue_t)queue {
    return AudioObjectAddPropertyListenerBlock(object, &address, queue, _block);
}

- (OSStatus)removeForObject:(AudioObjectID)object address:(AudioObjectPropertyAddress)address queue:(dispatch_queue_t)queue {
    return AudioObjectRemovePropertyListenerBlock(object, &address, queue, _block);
}

#if !__has_feature(objc_arc)
- (void)dealloc {
    [_block release];
    [super dealloc];
}
#endif

@end
