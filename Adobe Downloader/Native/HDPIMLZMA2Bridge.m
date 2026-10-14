#import "HDPIMLZMA2Bridge.h"
#include "7zip/Lzma2Dec.h"
#include "minizip-ng/mz.h"
#include "minizip-ng/mz_strm.h"
#include "minizip-ng/mz_strm_os.h"
#include "minizip-ng/mz_zip.h"
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

const int32_t HDPIMZipValidationCancelled = -1000;

typedef struct {
    mz_stream stream;
    HDPIMZipValidationCancellationHandler shouldCancel;
    void *context;
    int32_t error;
} HDPIMZipValidationStream;

static int32_t HDPIMZipValidationStreamIsOpen(void *handle) {
    HDPIMZipValidationStream *stream = handle;
    return mz_stream_os_is_open(stream->stream.base);
}

static int32_t HDPIMZipValidationStreamRead(void *handle, void *buffer, int32_t size) {
    HDPIMZipValidationStream *stream = handle;
    if (stream->shouldCancel && stream->shouldCancel(stream->context)) {
        stream->error = HDPIMZipValidationCancelled;
        return stream->error;
    }
    if (size < 0) {
        return MZ_PARAM_ERROR;
    }
    int32_t count = mz_stream_os_read(stream->stream.base, buffer, size);
    if (count == 0 && size > 0) {
        count = MZ_READ_ERROR;
    }
    if (count < 0) {
        stream->error = count;
    }
    return count;
}

static int64_t HDPIMZipValidationStreamTell(void *handle) {
    HDPIMZipValidationStream *stream = handle;
    return mz_stream_os_tell(stream->stream.base);
}

static int32_t HDPIMZipValidationStreamSeek(void *handle, int64_t offset, int32_t origin) {
    HDPIMZipValidationStream *stream = handle;
    return mz_stream_os_seek(stream->stream.base, offset, origin);
}

static int32_t HDPIMZipValidationStreamError(void *handle) {
    HDPIMZipValidationStream *stream = handle;
    return stream->error != MZ_OK ? stream->error : mz_stream_os_error(stream->stream.base);
}

static mz_stream_vtbl HDPIMZipValidationStreamInterface = {
    .is_open = HDPIMZipValidationStreamIsOpen,
    .read = HDPIMZipValidationStreamRead,
    .tell = HDPIMZipValidationStreamTell,
    .seek = HDPIMZipValidationStreamSeek,
    .error = HDPIMZipValidationStreamError
};

static int32_t HDPIMCheckZipEntrySupport(const mz_zip_file *info) {
    if ((info->flag & MZ_ZIP_FLAG_ENCRYPTED) || info->aes_version != 0 || info->disk_number != 0) {
        return MZ_SUPPORT_ERROR;
    }
    if (info->compressed_size < 0 || info->uncompressed_size < 0 || info->disk_offset < 0) {
        return MZ_FORMAT_ERROR;
    }
    switch (info->compression_method) {
        case MZ_COMPRESS_METHOD_STORE:
        case MZ_COMPRESS_METHOD_DEFLATE:
        case MZ_COMPRESS_METHOD_BZIP2:
            return MZ_OK;
        default:
            return MZ_SUPPORT_ERROR;
    }
}

static int32_t HDPIMValidateZipEntryContents(
    void *archive,
    const mz_zip_file *info,
    HDPIMZipValidationCancellationHandler shouldCancel,
    void *context
) {
    int32_t result = mz_zip_entry_read_open(archive, 0, NULL);
    if (result != MZ_OK) {
        return result;
    }

    mz_zip_file *localInfo = NULL;
    result = mz_zip_entry_get_local_info(archive, &localInfo);
    if (result == MZ_OK) {
        result = HDPIMCheckZipEntrySupport(localInfo);
    }
    if (result == MZ_OK &&
        (localInfo->compression_method != info->compression_method ||
         localInfo->flag != info->flag ||
         localInfo->filename_size != info->filename_size ||
         memcmp(localInfo->filename, info->filename, info->filename_size) != 0)) {
        result = MZ_FORMAT_ERROR;
    }
    if (result == MZ_OK && !(info->flag & MZ_ZIP_FLAG_DATA_DESCRIPTOR) &&
        (localInfo->compressed_size != info->compressed_size ||
         localInfo->uncompressed_size != info->uncompressed_size ||
         localInfo->crc != info->crc)) {
        result = MZ_FORMAT_ERROR;
    }

    uint8_t buffer[256 * 1024];
    int64_t bytesRead = 0;
    uint32_t actualCRC = (uint32_t)crc32(0, Z_NULL, 0);
    while (result == MZ_OK) {
        if (shouldCancel && shouldCancel(context)) {
            result = HDPIMZipValidationCancelled;
            break;
        }
        int32_t count = mz_zip_entry_read(archive, buffer, (int32_t)sizeof(buffer));
        if (count < 0) {
            result = count;
            break;
        }
        if (count == 0) {
            break;
        }
        if (count > info->uncompressed_size - bytesRead) {
            result = MZ_FORMAT_ERROR;
            break;
        }
        bytesRead += count;
        actualCRC = (uint32_t)crc32(actualCRC, buffer, (uInt)count);
    }
    if (result == MZ_OK && bytesRead != info->uncompressed_size) {
        result = MZ_FORMAT_ERROR;
    }
    if (result == MZ_OK && actualCRC != info->crc) {
        result = MZ_CRC_ERROR;
    }
    if (result == MZ_OK) {
        void *compressionStream = NULL;
        int64_t compressedBytesRead = 0;
        result = mz_zip_entry_get_compress_stream(archive, &compressionStream);
        if (result == MZ_OK) {
            result = mz_stream_get_prop_int64(compressionStream, MZ_STREAM_PROP_TOTAL_IN, &compressedBytesRead);
        }
        if (result == MZ_OK && compressedBytesRead != info->compressed_size) {
            result = MZ_FORMAT_ERROR;
        }
    }

    uint32_t descriptorCRC = 0;
    int64_t descriptorCompressedSize = 0;
    int64_t descriptorUncompressedSize = 0;
    int32_t closeResult = mz_zip_entry_read_close(
        archive,
        result == MZ_OK ? &descriptorCRC : NULL,
        result == MZ_OK ? &descriptorCompressedSize : NULL,
        result == MZ_OK ? &descriptorUncompressedSize : NULL
    );
    if (result == MZ_OK) {
        result = closeResult;
    }
    if (result == MZ_OK &&
        (descriptorCompressedSize != info->compressed_size ||
         descriptorUncompressedSize != info->uncompressed_size)) {
        result = MZ_FORMAT_ERROR;
    }
    if (result == MZ_OK && descriptorCRC != info->crc) {
        result = MZ_CRC_ERROR;
    }
    return result;
}

int32_t HDPIMValidateZipArchive(const char *path, int32_t validateContents) {
    return HDPIMValidateZipArchiveWithCancellation(path, validateContents, NULL, NULL);
}

int32_t HDPIMValidateZipArchiveWithCancellation(
    const char *path,
    int32_t validateContents,
    HDPIMZipValidationCancellationHandler shouldCancel,
    void *context
) {
    if (!path || path[0] == '\0') {
        return MZ_PARAM_ERROR;
    }
    if (shouldCancel && shouldCancel(context)) {
        return HDPIMZipValidationCancelled;
    }

    void *stream = mz_stream_os_create();
    void *archive = mz_zip_create();
    HDPIMZipValidationStream validationStream = {
        .stream = { .vtbl = &HDPIMZipValidationStreamInterface, .base = stream },
        .shouldCancel = shouldCancel,
        .context = context,
        .error = MZ_OK
    };
    int32_t result = (stream && archive) ? MZ_OK : MZ_MEM_ERROR;
    if (result == MZ_OK) {
        result = mz_stream_os_open(stream, path, MZ_OPEN_MODE_READ);
    }
    if (result == MZ_OK) {
        result = mz_zip_set_recover(archive, 0);
    }
    if (result == MZ_OK) {
        result = mz_zip_open(archive, &validationStream, MZ_OPEN_MODE_READ);
    }

    uint64_t expectedEntries = 0;
    uint64_t actualEntries = 0;
    uint32_t directoryDiskNumber = 0;
    if (result == MZ_OK) {
        result = mz_zip_get_disk_number_with_cd(archive, &directoryDiskNumber);
    }
    if (result == MZ_OK && directoryDiskNumber != 0) {
        result = MZ_SUPPORT_ERROR;
    }
    if (result == MZ_OK) {
        result = mz_zip_get_number_entry(archive, &expectedEntries);
    }
    if (result == MZ_OK) {
        result = mz_zip_goto_first_entry(archive);
        while (result == MZ_OK) {
            if (shouldCancel && shouldCancel(context)) {
                result = HDPIMZipValidationCancelled;
                break;
            }
            if (actualEntries == expectedEntries) {
                result = MZ_FORMAT_ERROR;
                break;
            }
            mz_zip_file *info = NULL;
            result = mz_zip_entry_get_info(archive, &info);
            if (result == MZ_OK) {
                result = HDPIMCheckZipEntrySupport(info);
            }
            if (result == MZ_OK && validateContents != 0) {
                result = HDPIMValidateZipEntryContents(archive, info, shouldCancel, context);
            }
            if (result != MZ_OK) {
                break;
            }
            actualEntries += 1;
            result = mz_zip_goto_next_entry(archive);
        }
        if (result == MZ_END_OF_LIST) {
            result = actualEntries == expectedEntries ? MZ_OK : MZ_FORMAT_ERROR;
        }
    }

    if (archive) {
        int32_t closeResult = mz_zip_close(archive);
        if (result == MZ_OK) {
            result = closeResult;
        }
        mz_zip_delete(&archive);
    }
    if (stream) {
        int32_t closeResult = mz_stream_os_close(stream);
        if (result == MZ_OK) {
            result = closeResult;
        }
        mz_stream_os_delete(&stream);
    }
    if (shouldCancel && shouldCancel(context)) {
        result = HDPIMZipValidationCancelled;
    }
    return result;
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

@implementation HDPIMBZ2StreamReader {
    NSData *_input;
    NSUInteger _inputOffset;
    bz_stream _stream;
    BOOL _initialized;
    BOOL _finished;
    BOOL _failed;
}

- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _input = [data copy];
    int result = BZ2_bzDecompressInit(&_stream, 0, 0);
    if (result != BZ_OK) {
        if (error) *error = HDPIMMakeBZ2Error([NSString stringWithFormat:@"bzip2 初始化失败: %d", result]);
        return nil;
    }
    _initialized = YES;
    return self;
}

- (nullable NSData *)readUpToLength:(NSUInteger)length error:(NSError **)error {
    if (_failed || length == 0 || length > 1024 * 1024) {
        if (error) *error = HDPIMMakeBZ2Error(@"bzip2 读取状态或分块大小无效");
        return nil;
    }
    if (_finished) return [NSData data];
    NSMutableData *output = [NSMutableData dataWithLength:length];
    _stream.next_out = output.mutableBytes;
    _stream.avail_out = (unsigned int)length;
    while (_stream.avail_out > 0) {
        if (_stream.avail_in == 0 && _inputOffset < _input.length) {
            NSUInteger count = MIN(_input.length - _inputOffset, (NSUInteger)UINT_MAX);
            _stream.next_in = (char *)_input.bytes + _inputOffset;
            _stream.avail_in = (unsigned int)count;
            _inputOffset += count;
        }
        unsigned int beforeInput = _stream.avail_in;
        unsigned int beforeOutput = _stream.avail_out;
        int result = BZ2_bzDecompress(&_stream);
        if (result == BZ_STREAM_END) {
            _finished = YES;
            break;
        }
        if (result != BZ_OK || (beforeInput == _stream.avail_in && beforeOutput == _stream.avail_out)) {
            _failed = YES;
            _stream.next_out = NULL;
            _stream.avail_out = 0;
            if (error) *error = HDPIMMakeBZ2Error([NSString stringWithFormat:@"bzip2 解码失败或数据截断: %d", result]);
            return nil;
        }
    }
    output.length = length - _stream.avail_out;
    _stream.next_out = NULL;
    _stream.avail_out = 0;
    return output;
}

- (void)dealloc {
    if (_initialized) BZ2_bzDecompressEnd(&_stream);
}
@end

@interface HDPIMLZMA2FileDecoder () {
    CLzma2Dec _decoder;
    NSMutableData *_dictionary;
    uint64_t _expectedSize;
    uint64_t _compressedBodySize;
    uint64_t _receivedSize;
    uint64_t _consumedSize;
    uint64_t _decodedSize;
    uint64_t _paddingRemaining;
    BOOL _allocated;
    BOOL _finished;
}
@end

@implementation HDPIMLZMA2FileDecoder

- (nullable instancetype)initWithPropertyByte:(uint8_t)propertyByte
                                expectedSize:(uint64_t)expectedSize
                          compressedBodySize:(uint64_t)compressedBodySize
                                       error:(NSError **)error {
    self = [super init];
    if (!self || !HDPIMValidateLZMA2Property(propertyByte, error)) { return nil; }
    Lzma2Dec_Construct(&_decoder);
    SRes result = Lzma2Dec_AllocateProbs(&_decoder, propertyByte, &HDPIMSevenZipAllocator);
    if (result != SZ_OK) {
        if (error) { *error = HDPIMMakeLZMAError(@"无法分配 LZMA2 状态"); }
        return nil;
    }
    _allocated = YES;
    uint64_t declaredDictionary = propertyByte == 40 ? UINT32_MAX : ((uint64_t)(2 | (propertyByte & 1)) << ((propertyByte >> 1) + 11));
    uint64_t capacity = MIN(declaredDictionary, MAX(expectedSize, (uint64_t)1));
    _dictionary = [NSMutableData dataWithLength:(NSUInteger)capacity];
    _decoder.decoder.dic = _dictionary.mutableBytes;
    _decoder.decoder.dicBufSize = (SizeT)capacity;
    Lzma2Dec_Init(&_decoder);
    _expectedSize = expectedSize;
    _compressedBodySize = compressedBodySize;
    return self;
}

- (void)dealloc {
    if (_allocated) { Lzma2Dec_FreeProbs(&_decoder, &HDPIMSevenZipAllocator); }
}

- (uint64_t)decodedSize { return _decodedSize; }

- (BOOL)emit:(const Byte *)bytes length:(SizeT)length handler:(HDPIMLZMA2OutputHandler)handler error:(NSError **)error {
    if (length > _expectedSize - _decodedSize) {
        if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 输出超过声明长度"); }
        return NO;
    }
    if (length > 0) {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
        if (!handler(data, error)) { return NO; }
        _decodedSize += length;
    }
    return YES;
}

- (BOOL)consumeTail:(const Byte *)bytes length:(SizeT)length handler:(HDPIMLZMA2OutputHandler)handler error:(NSError **)error {
    SizeT padding = (SizeT)MIN(_paddingRemaining, (uint64_t)length);
    for (SizeT index = 0; index < padding; index++) {
        if (bytes[index] != 0) {
            if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 raw tail 填充数据无效"); }
            return NO;
        }
    }
    _paddingRemaining -= padding;
    return [self emit:bytes + padding length:length - padding handler:handler error:error];
}

- (BOOL)processChunk:(NSData *)chunk outputHandler:(HDPIMLZMA2OutputHandler)outputHandler error:(NSError **)error {
    if (chunk.length > _compressedBodySize - _receivedSize) {
        if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 输入超过声明长度"); }
        return NO;
    }
    _receivedSize += chunk.length;
    if (_finished) { return [self consumeTail:chunk.bytes length:chunk.length handler:outputHandler error:error]; }
    const Byte *input = chunk.bytes;
    SizeT remaining = chunk.length;
    while (remaining > 0) {
        Byte output[128 * 1024];
        SizeT outputSize = sizeof(output);
        SizeT consumed = remaining;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
        SRes result = Lzma2Dec_DecodeToBuf(&_decoder, output, &outputSize, input, &consumed, LZMA_FINISH_ANY, &status);
        if (result != SZ_OK) {
            if (error) { *error = HDPIMMakeLZMAError(HDPIMLZMAResultMessage(result, status)); }
            return NO;
        }
        if (![self emit:output length:outputSize handler:outputHandler error:error]) { return NO; }
        input += consumed;
        remaining -= consumed;
        _consumedSize += consumed;
        if (status == LZMA_STATUS_FINISHED_WITH_MARK) {
            _finished = YES;
            uint64_t missingOutput = _expectedSize - _decodedSize;
            uint64_t tailSize = _compressedBodySize - _consumedSize;
            if (tailSize < missingOutput) {
                if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 raw tail 长度不足"); }
                return NO;
            }
            _paddingRemaining = tailSize - missingOutput;
            return [self consumeTail:input length:remaining handler:outputHandler error:error];
        }
        if (consumed == 0 && outputSize == 0) {
            if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 解码没有推进"); }
            return NO;
        }
    }
    return YES;
}

- (BOOL)finishWithOutputHandler:(HDPIMLZMA2OutputHandler)outputHandler error:(NSError **)error {
    while (!_finished) {
        Byte output[128 * 1024];
        SizeT outputSize = sizeof(output);
        SizeT consumed = 0;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
        SRes result = Lzma2Dec_DecodeToBuf(&_decoder, output, &outputSize, NULL, &consumed, LZMA_FINISH_ANY, &status);
        if (result != SZ_OK || ![self emit:output length:outputSize handler:outputHandler error:error]) {
            if (result != SZ_OK && error) { *error = HDPIMMakeLZMAError(HDPIMLZMAResultMessage(result, status)); }
            return NO;
        }
        if (status == LZMA_STATUS_FINISHED_WITH_MARK) { _finished = YES; }
        else if (outputSize == 0) {
            if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 流缺少结束标记"); }
            return NO;
        }
    }
    if (_decodedSize != _expectedSize || _receivedSize != _compressedBodySize || _paddingRemaining != 0) {
        if (error) { *error = HDPIMMakeLZMAError(@"LZMA2 输入、输出或尾部长度不匹配"); }
        return NO;
    }
    return YES;
}
@end

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
