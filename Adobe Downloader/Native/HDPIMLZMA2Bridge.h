#import <Foundation/Foundation.h>
#include <stdbool.h>
#import "minizip-ng/compat/unzip.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSData * _Nullable HDPIMLZMA2Decompress(NSData *input, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable HDPIMBZ2Decompress(NSData *input, NSError **error);

@interface HDPIMBZ2StreamReader : NSObject
- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable NSData *)readUpToLength:(NSUInteger)length error:(NSError **)error NS_SWIFT_NAME(read(upToLength:));
@end

FOUNDATION_EXPORT uint32_t HDPIMCRC32(uint32_t crc, NSData *data);

FOUNDATION_EXPORT const int32_t HDPIMZipValidationCancelled;
typedef bool (*HDPIMZipValidationCancellationHandler)(void * _Nullable context);

FOUNDATION_EXPORT int32_t HDPIMValidateZipArchive(const char *path, int32_t validateContents);
FOUNDATION_EXPORT int32_t HDPIMValidateZipArchiveWithCancellation(
    const char *path,
    int32_t validateContents,
    HDPIMZipValidationCancellationHandler _Nullable shouldCancel,
    void * _Nullable context
);
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

typedef BOOL (^HDPIMLZMA2OutputHandler)(NSData *data, NSError **error);

@interface HDPIMLZMA2FileDecoder : NSObject
- (nullable instancetype)initWithPropertyByte:(uint8_t)propertyByte
                                expectedSize:(uint64_t)expectedSize
                          compressedBodySize:(uint64_t)compressedBodySize
                                       error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)processChunk:(NSData *)chunk outputHandler:(HDPIMLZMA2OutputHandler)outputHandler error:(NSError **)error;
- (BOOL)finishWithOutputHandler:(HDPIMLZMA2OutputHandler)outputHandler error:(NSError **)error;
@property (nonatomic, readonly) uint64_t decodedSize;
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
