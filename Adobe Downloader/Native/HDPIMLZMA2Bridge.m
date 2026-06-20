#import "HDPIMLZMA2Bridge.h"
#include "7zip/Lzma2Dec.h"
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <zlib.h>
#include <bzlib.h>

static NSError *HDPIMMakeLZMAError(NSString *message) {
    return [NSError errorWithDomain:@"HDPIMLZMA2"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void *HDPIMSevenZipAlloc(ISzAllocPtr allocator, size_t size) {
    (void)allocator;
    return size == 0 ? NULL : malloc(size);
}

static void HDPIMSevenZipFree(ISzAllocPtr allocator, void *address) {
    (void)allocator;
    free(address);
}

static const ISzAlloc HDPIMSevenZipAllocator = { HDPIMSevenZipAlloc, HDPIMSevenZipFree };

static BOOL HDPIMValidateLZMA2Property(uint8_t propertyByte, NSError **error) {
    if (propertyByte > 40) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 字典大小字节无效");
        }
        return NO;
    }

    return YES;
}

uint32_t HDPIMCRC32(uint32_t crc, NSData *data) {
    return (uint32_t)crc32(crc, data.bytes, (uInt)data.length);
}

BOOL HDPIMUnpackAppleDouble(NSString *appleDoubleFilePath, NSString *targetFilePath, NSError **error) {
    copyfile_flags_t flags = COPYFILE_UNPACK | COPYFILE_NOFOLLOW_SRC | COPYFILE_XATTR | COPYFILE_ACL;
    int result = copyfile(appleDoubleFilePath.fileSystemRepresentation,
                          targetFilePath.fileSystemRepresentation,
                          NULL,
                          flags);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return NO;
    }
    return YES;
}

static NSString *HDPIMLZMAResultMessage(SRes result, ELzmaStatus status) {
    return [NSString stringWithFormat:@"7-Zip LZMA2 解码失败: result=%d status=%d", result, status];
}

@interface HDPIMLZMA2StreamDecoder () {
    CLzma2Dec _decoder;
    BOOL _finished;
    BOOL _allocated;
}
@end

@implementation HDPIMLZMA2StreamDecoder

- (nullable instancetype)initWithDictionaryByte:(uint8_t)dictSizeByte
                                          error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!HDPIMValidateLZMA2Property(dictSizeByte, error)) {
        return nil;
    }

    Lzma2Dec_Construct(&_decoder);
    SRes setup = Lzma2Dec_Allocate(&_decoder, dictSizeByte, &HDPIMSevenZipAllocator);
    if (setup != SZ_OK) {
        if (error) {
            *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"初始化 7-Zip LZMA2 解码器失败: %d", setup]);
        }
        return nil;
    }

    _allocated = YES;
    _finished = NO;
    Lzma2Dec_Init(&_decoder);
    return self;
}

- (void)dealloc {
    if (_allocated) {
        Lzma2Dec_Free(&_decoder, &HDPIMSevenZipAllocator);
    }
}

- (nullable NSData *)processChunk:(NSData *)chunk
                           finish:(BOOL)finish
                            error:(NSError **)error {
    if (_finished) {
        return [NSData data];
    }

    const Byte *input = chunk.bytes;
    SizeT remaining = chunk.length;
    NSMutableData *output = [NSMutableData data];

    while (YES) {
        uint8_t buffer[64 * 1024];
        SizeT outputSize = sizeof(buffer);
        SizeT inputSize = remaining;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
        SRes result = Lzma2Dec_DecodeToBuf(
            &_decoder,
            buffer,
            &outputSize,
            input,
            &inputSize,
            LZMA_FINISH_ANY,
            &status
        );

        if (result != SZ_OK) {
            if (error) {
                *error = HDPIMMakeLZMAError(HDPIMLZMAResultMessage(result, status));
            }
            return nil;
        }

        if (outputSize > 0) {
            [output appendBytes:buffer length:outputSize];
        }

        input += inputSize;
        remaining -= inputSize;

        if (status == LZMA_STATUS_FINISHED_WITH_MARK) {
            _finished = YES;
            break;
        }

        if (remaining == 0 && !finish) {
            break;
        }

        if (remaining == 0 && finish && outputSize == 0) {
            if (error) {
                *error = HDPIMMakeLZMAError(@"7-Zip LZMA2 解码未正常结束");
            }
            return nil;
        }

        if (inputSize == 0 && outputSize == 0) {
            if (error) {
                *error = HDPIMMakeLZMAError(@"7-Zip LZMA2 解码没有推进");
            }
            return nil;
        }
    }

    return output;
}

@end

NSData *HDPIMLZMA2Decompress(NSData *input, NSError **error) {
    if (input.length < 2) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 输入数据过短");
        }
        return nil;
    }

    const uint8_t *bytes = input.bytes;
    HDPIMLZMA2StreamDecoder *decoder = [[HDPIMLZMA2StreamDecoder alloc] initWithDictionaryByte:bytes[0] error:error];
    if (!decoder) {
        return nil;
    }

    NSData *body = [NSData dataWithBytesNoCopy:(void *)(bytes + 1)
                                        length:input.length - 1
                                  freeWhenDone:NO];
    return [decoder processChunk:body finish:YES error:error];
}

static NSError *HDPIMMakeBZ2Error(NSString *message) {
    return [NSError errorWithDomain:@"HDPIMBZ2"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSData *HDPIMBZ2Decompress(NSData *input, NSError **error) {
    if (input.length == 0) {
        if (error) {
            *error = HDPIMMakeBZ2Error(@"bzip2 输入数据为空");
        }
        return nil;
    }

    NSUInteger initialCapacity = input.length * 8;
    if (initialCapacity < 65536) {
        initialCapacity = 65536;
    }
    const unsigned int maxCapacity = 512u * 1024u * 1024u;
    if (initialCapacity > maxCapacity) {
        initialCapacity = maxCapacity;
    }

    unsigned int capacity = (unsigned int)initialCapacity;
    while (YES) {
        NSMutableData *output = [NSMutableData dataWithLength:capacity];
        unsigned int destLen = capacity;
        int result = BZ2_bzBuffToBuffDecompress((char *)output.mutableBytes,
                                                 &destLen,
                                                 (char *)input.bytes,
                                                 (unsigned int)input.length,
                                                 0,
                                                 0);
        if (result == BZ_OK) {
            output.length = destLen;
            return output;
        }
        if (result == BZ_OUTBUFF_FULL && capacity < maxCapacity) {
            unsigned int next = capacity * 2;
            if (next > maxCapacity || next < capacity) {
                next = maxCapacity;
            }
            capacity = next;
            continue;
        }
        if (error) {
            *error = HDPIMMakeBZ2Error([NSString stringWithFormat:@"bzip2 解码失败: result=%d", result]);
        }
        return nil;
    }
}

@interface HDPIMSevenZipLZMA2Decoder () {
    CLzma2Dec _decoder;
    NSMutableData *_dictionary;
    UInt64 _expectedSize;
    UInt64 _compressedBodySize;
    UInt64 _consumedBodySize;
    UInt64 _tailBytesToSkip;
    UInt64 _outputCapacity;
    BOOL _allocated;
    BOOL _finished;
    BOOL _tailOutputStarted;
}
@end

@implementation HDPIMSevenZipLZMA2Decoder

- (nullable instancetype)initWithPropertyByte:(uint8_t)propertyByte
                                 expectedSize:(uint64_t)expectedSize
                           compressedBodySize:(uint64_t)compressedBodySize
                                         error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!HDPIMValidateLZMA2Property(propertyByte, error)) {
        return nil;
    }

    if (expectedSize > UINT64_MAX - 0x10000) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 输出缓冲区大小溢出");
        }
        return nil;
    }

    uint64_t outputCapacity = expectedSize + 0x10000;
    if (outputCapacity == 0 || outputCapacity > NSUIntegerMax) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 输出缓冲区大小无效");
        }
        return nil;
    }

    Lzma2Dec_Construct(&_decoder);
    SRes setup = Lzma2Dec_AllocateProbs(&_decoder, propertyByte, &HDPIMSevenZipAllocator);
    if (setup != SZ_OK) {
        if (error) {
            *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"初始化 7-Zip LZMA2 字典解码器失败: %d", setup]);
        }
        return nil;
    }

    _allocated = YES;
    _expectedSize = expectedSize;
    _compressedBodySize = compressedBodySize;
    _consumedBodySize = 0;
    _tailBytesToSkip = 0;
    _outputCapacity = outputCapacity;
    _dictionary = [NSMutableData dataWithLength:(NSUInteger)outputCapacity];
    _decoder.decoder.dic = (Byte *)_dictionary.mutableBytes;
    _decoder.decoder.dicBufSize = (SizeT)outputCapacity;
    _decoder.decoder.dicPos = 0;
    Lzma2Dec_Init(&_decoder);
    return self;
}

- (void)dealloc {
    if (_allocated) {
        Lzma2Dec_FreeProbs(&_decoder, &HDPIMSevenZipAllocator);
    }
}

- (BOOL)appendTailBytes:(const Byte *)bytes length:(SizeT)length error:(NSError **)error {
    if (length == 0 || _expectedSize == 0) {
        return YES;
    }

    SizeT offset = 0;
    while (_tailBytesToSkip > 0 && offset < length) {
        SizeT skipSize = (SizeT)MIN((UInt64)(length - offset), _tailBytesToSkip);
        for (SizeT index = 0; index < skipSize; index++) {
            if (bytes[offset + index] != 0) {
                if (error) {
                    *error = HDPIMMakeLZMAError(@"LZMA2 raw tail 填充数据无效");
                }
                return NO;
            }
        }
        offset += skipSize;
        _tailBytesToSkip -= skipSize;
    }

    if (offset >= length || (UInt64)_dictionary.length >= _expectedSize) {
        return YES;
    }

    UInt64 remainingOutput = _expectedSize - (UInt64)_dictionary.length;
    SizeT appendSize = (SizeT)MIN((UInt64)(length - offset), remainingOutput);
    [_dictionary appendBytes:bytes + offset length:appendSize];
    return YES;
}

- (BOOL)startTailOutputWithBytes:(const Byte *)bytes length:(SizeT)length error:(NSError **)error {
    if (!_tailOutputStarted) {
        UInt64 writtenSize = (UInt64)_decoder.decoder.dicPos;
        _dictionary.length = (NSUInteger)writtenSize;
        _tailOutputStarted = YES;
    }

    return [self appendTailBytes:bytes length:length error:error];
}

- (BOOL)processChunk:(NSData *)chunk error:(NSError **)error {
    if (_finished) {
        return [self appendTailBytes:chunk.bytes length:chunk.length error:error];
    }

    const Byte *input = chunk.bytes;
    SizeT remaining = chunk.length;

    while (remaining > 0) {
        SizeT inputSize = remaining;
        SizeT previousPosition = _decoder.decoder.dicPos;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
        SRes result = Lzma2Dec_DecodeToDic(
            &_decoder,
            (SizeT)_outputCapacity,
            input,
            &inputSize,
            LZMA_FINISH_END,
            &status
        );

        if (result != SZ_OK) {
            if (error) {
                *error = HDPIMMakeLZMAError(HDPIMLZMAResultMessage(result, status));
            }
            return NO;
        }

        input += inputSize;
        remaining -= inputSize;
        _consumedBodySize += inputSize;

        if (status == LZMA_STATUS_FINISHED_WITH_MARK) {
            _finished = YES;
            UInt64 writtenSize = (UInt64)_decoder.decoder.dicPos;
            UInt64 missingOutput = _expectedSize > writtenSize ? _expectedSize - writtenSize : 0;
            UInt64 totalTailSize = _compressedBodySize > _consumedBodySize ? _compressedBodySize - _consumedBodySize : (UInt64)remaining;
            _tailBytesToSkip = totalTailSize > missingOutput ? totalTailSize - missingOutput : 0;
            if (![self startTailOutputWithBytes:input length:remaining error:error]) {
                return NO;
            }
            break;
        }

        if (_decoder.decoder.dicPos >= (SizeT)_outputCapacity && remaining > 0) {
            if (error) {
                *error = HDPIMMakeLZMAError(@"LZMA2 输出超过预期缓冲区");
            }
            return NO;
        }

        if (inputSize == 0 && _decoder.decoder.dicPos == previousPosition) {
            if (error) {
                *error = HDPIMMakeLZMAError(@"7-Zip LZMA2 字典解码没有推进");
            }
            return NO;
        }
    }

    return YES;
}

- (nullable NSData *)finishWithExpectedSize:(uint64_t)expectedSize error:(NSError **)error {
    if (!_finished) {
        SizeT inputSize = 0;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
        SRes result = Lzma2Dec_DecodeToDic(
            &_decoder,
            (SizeT)_outputCapacity,
            NULL,
            &inputSize,
            LZMA_FINISH_END,
            &status
        );

        uint64_t writtenSize = (uint64_t)_decoder.decoder.dicPos;
        if (result != SZ_OK || (status != LZMA_STATUS_FINISHED_WITH_MARK && writtenSize != expectedSize)) {
            if (error) {
                *error = HDPIMMakeLZMAError(HDPIMLZMAResultMessage(result, status));
            }
            return nil;
        }

        _finished = YES;
    }

    if (_tailBytesToSkip > 0) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 raw tail 填充数据不完整");
        }
        return nil;
    }

    uint64_t writtenSize = _tailOutputStarted ? (uint64_t)_dictionary.length : (uint64_t)_decoder.decoder.dicPos;
    if (writtenSize != expectedSize) {
        if (error) {
            *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"LZMA2 解压大小不匹配: %llu/%llu", writtenSize, expectedSize]);
        }
        return nil;
    }

    if (!_tailOutputStarted) {
        _dictionary.length = (NSUInteger)writtenSize;
    }
    return _dictionary;
}

- (nullable NSNumber *)finishWithExpectedSize:(uint64_t)expectedSize
                                writingToPath:(NSString *)path
                                        error:(NSError **)error {
    NSData *output = [self finishWithExpectedSize:expectedSize error:error];
    if (!output) {
        return nil;
    }

    int fileDescriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fileDescriptor < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }

    const uint8_t *bytes = output.bytes;
    NSUInteger totalSize = output.length;
    NSUInteger writtenSize = 0;

    while (writtenSize < totalSize) {
        NSUInteger remainingSize = totalSize - writtenSize;
        size_t chunkSize = (size_t)MIN(remainingSize, (NSUInteger)(16 * 1024 * 1024));
        ssize_t result = write(fileDescriptor, bytes + writtenSize, chunkSize);

        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            int savedErrno = errno;
            close(fileDescriptor);
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
            }
            return nil;
        }

        if (result == 0) {
            close(fileDescriptor);
            if (error) {
                *error = HDPIMMakeLZMAError(@"LZMA2 输出写入没有推进");
            }
            return nil;
        }

        writtenSize += (NSUInteger)result;
    }

    if (close(fileDescriptor) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }

    return @(writtenSize);
}

@end
