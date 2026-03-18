#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSData * _Nullable HDPIMLZMA2Decompress(NSData *input, NSError **error);

@interface HDPIMLZMA2StreamDecoder : NSObject

- (nullable instancetype)initWithDictionaryByte:(uint8_t)dictSizeByte
                                          error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NSData *)processChunk:(NSData *)chunk
                           finish:(BOOL)finish
                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
