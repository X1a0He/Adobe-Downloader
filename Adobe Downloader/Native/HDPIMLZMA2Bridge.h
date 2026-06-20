#import <Foundation/Foundation.h>
#import "minizip-ng/compat/unzip.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSData * _Nullable HDPIMLZMA2Decompress(NSData *input, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable HDPIMBZ2Decompress(NSData *input, NSError **error);
FOUNDATION_EXPORT uint32_t HDPIMCRC32(uint32_t crc, NSData *data);
FOUNDATION_EXPORT BOOL HDPIMUnpackAppleDouble(NSString *appleDoubleFilePath, NSString *targetFilePath, NSError **error);

@interface HDPIMLZMA2StreamDecoder : NSObject

- (nullable instancetype)initWithDictionaryByte:(uint8_t)dictSizeByte
                                          error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NSData *)processChunk:(NSData *)chunk
                           finish:(BOOL)finish
                            error:(NSError **)error;

@end

@interface HDPIMSevenZipLZMA2Decoder : NSObject

- (nullable instancetype)initWithPropertyByte:(uint8_t)propertyByte
                                 expectedSize:(uint64_t)expectedSize
                           compressedBodySize:(uint64_t)compressedBodySize
                                         error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)processChunk:(NSData *)chunk error:(NSError **)error;
- (nullable NSData *)finishWithExpectedSize:(uint64_t)expectedSize error:(NSError **)error;
- (nullable NSNumber *)finishWithExpectedSize:(uint64_t)expectedSize
                                writingToPath:(NSString *)path
                                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
