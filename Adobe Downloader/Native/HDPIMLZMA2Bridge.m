#import "HDPIMLZMA2Bridge.h"
#include <lzma.h>

static NSError *HDPIMMakeLZMAError(NSString *message) {
    return [NSError errorWithDomain:@"HDPIMLZMA2"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL HDPIMExtractDictionarySize(uint8_t dictSizeByte, uint32_t *dictSize, NSError **error) {
    if ((dictSizeByte & 0xC0) != 0) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 字典大小字节无效");
        }
        return NO;
    }

    uint8_t bits = dictSizeByte & 0x3F;
    if (bits >= 40) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 字典大小超出范围");
        }
        return NO;
    }

    *dictSize = (uint32_t)(2 | (bits & 1)) << (bits / 2 + 11);
    return YES;
}

NSData *HDPIMLZMA2Decompress(NSData *input, NSError **error) {
    if (input.length < 2) {
        if (error) {
            *error = HDPIMMakeLZMAError(@"LZMA2 输入数据过短");
        }
        return nil;
    }

    const uint8_t *bytes = input.bytes;
    uint32_t dictSize = 0;
    if (!HDPIMExtractDictionarySize(bytes[0], &dictSize, error)) {
        return nil;
    }

    lzma_options_lzma options;
    memset(&options, 0, sizeof(options));
    options.dict_size = dictSize;

    lzma_filter filters[2];
    filters[0].id = LZMA_FILTER_LZMA2;
    filters[0].options = &options;
    filters[1].id = LZMA_VLI_UNKNOWN;
    filters[1].options = NULL;

    lzma_stream stream = LZMA_STREAM_INIT;
    lzma_ret setup = lzma_raw_decoder(&stream, filters);
    if (setup != LZMA_OK) {
        if (error) {
            *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"初始化原生 LZMA2 解码器失败: %d", setup]);
        }
        return nil;
    }

    stream.next_in = bytes + 1;
    stream.avail_in = input.length - 1;

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[64 * 1024];

    while (YES) {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);

        lzma_action action = stream.avail_in == 0 ? LZMA_FINISH : LZMA_RUN;
        lzma_ret ret = lzma_code(&stream, action);

        size_t produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) {
            [output appendBytes:buffer length:produced];
        }

        if (ret == LZMA_STREAM_END) {
            break;
        }

        if (ret != LZMA_OK) {
            lzma_end(&stream);
            if (error) {
                *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"原生 LZMA2 解码失败: %d", ret]);
            }
            return nil;
        }

        if (action == LZMA_FINISH && produced == 0) {
            lzma_end(&stream);
            if (error) {
                *error = HDPIMMakeLZMAError(@"原生 LZMA2 解码未正常结束");
            }
            return nil;
        }
    }

    lzma_end(&stream);
    return output;
}

@interface HDPIMLZMA2StreamDecoder () {
    lzma_stream _stream;
    BOOL _finished;
}
@end

@implementation HDPIMLZMA2StreamDecoder

- (nullable instancetype)initWithDictionaryByte:(uint8_t)dictSizeByte
                                          error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    uint32_t dictSize = 0;
    if (!HDPIMExtractDictionarySize(dictSizeByte, &dictSize, error)) {
        return nil;
    }

    _stream = (lzma_stream)LZMA_STREAM_INIT;

    lzma_options_lzma options;
    memset(&options, 0, sizeof(options));
    options.dict_size = dictSize;

    lzma_filter filters[2];
    filters[0].id = LZMA_FILTER_LZMA2;
    filters[0].options = &options;
    filters[1].id = LZMA_VLI_UNKNOWN;
    filters[1].options = NULL;

    lzma_ret setup = lzma_raw_decoder(&_stream, filters);
    if (setup != LZMA_OK) {
        if (error) {
            *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"初始化流式 LZMA2 解码器失败: %d", setup]);
        }
        return nil;
    }

    _finished = NO;
    return self;
}

- (void)dealloc {
    lzma_end(&_stream);
}

- (nullable NSData *)processChunk:(NSData *)chunk
                           finish:(BOOL)finish
                            error:(NSError **)error {
    if (_finished) {
        return [NSData data];
    }

    _stream.next_in = chunk.bytes;
    _stream.avail_in = chunk.length;

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[64 * 1024];

    while (YES) {
        _stream.next_out = buffer;
        _stream.avail_out = sizeof(buffer);

        lzma_action action = (finish && _stream.avail_in == 0) ? LZMA_FINISH : LZMA_RUN;
        lzma_ret ret = lzma_code(&_stream, action);

        size_t produced = sizeof(buffer) - _stream.avail_out;
        if (produced > 0) {
            [output appendBytes:buffer length:produced];
        }

        if (ret == LZMA_STREAM_END) {
            _finished = YES;
            break;
        }

        if (ret != LZMA_OK) {
            if (error) {
                *error = HDPIMMakeLZMAError([NSString stringWithFormat:@"流式 LZMA2 解码失败: %d", ret]);
            }
            return nil;
        }

        if (_stream.avail_in == 0 && _stream.avail_out != 0 && !finish) {
            break;
        }

        if (_stream.avail_in == 0 && _stream.avail_out != 0 && finish && produced == 0) {
            if (error) {
                *error = HDPIMMakeLZMAError(@"流式 LZMA2 解码未正常结束");
            }
            return nil;
        }
    }

    return output;
}

@end
