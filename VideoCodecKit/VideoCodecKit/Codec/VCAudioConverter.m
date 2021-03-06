//
//  VCAudioConverter.m
//  VideoCodecKit
//
//  Created by CmST0us on 2019/2/6.
//  Copyright © 2019 eric3u. All rights reserved.
//

#import "VCAudioConverter.h"
#import "VCAudioSpecificConfig.h"

@interface VCAudioConverter ()
@property (nonatomic, assign) AudioConverterRef converter;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;

@property (nonatomic, assign) AudioBufferList *currentBufferList;
@property (nonatomic, assign) AudioBufferList *feedBufferList;

@property (nonatomic, assign) AudioStreamPacketDescription currentAudioStreamPacketDescription;

@property (nonatomic, readonly) NSUInteger outputMaxBufferSize;
@property (nonatomic, readonly) NSUInteger ioOutputDataPacketSize;
@property (nonatomic, readonly) NSUInteger outputAudioBufferCount;
@property (nonatomic, readonly) NSUInteger outputNumberChannels;
@end

@implementation VCAudioConverter

static OSStatus audioConverterInputDataProc(AudioConverterRef inAudioConverter,
                                            UInt32 *          ioNumberDataPackets,
                                            AudioBufferList * ioData,
                                            AudioStreamPacketDescription * __nullable * __nullable outDataPacketDescription,
                                            void * __nullable inUserData) {
    VCAudioConverter *converter = (__bridge VCAudioConverter *)inUserData;
    return [converter converterInputDataProcWithConverter:inAudioConverter ioNumberDataPackets:ioNumberDataPackets ioData:ioData outDataPacketDescription:outDataPacketDescription];
}

- (OSStatus)converterInputDataProcWithConverter:(AudioConverterRef)inAudioConverter
                            ioNumberDataPackets:(UInt32 *)ioNumberDataPackets
                                         ioData:(AudioBufferList *)ioData
                       outDataPacketDescription:(AudioStreamPacketDescription **)outDataPacketDescription {
    memcpy(ioData, _currentBufferList, [self audioBufferListSizeWithBufferCount:ioData->mNumberBuffers]);
    if (_currentBufferList->mBuffers[0].mDataByteSize < *ioNumberDataPackets) {
        *ioNumberDataPackets = 0;
        return noErr;
    }
    // !!! if decode aac, must set outDataPacketDescription
    if (outDataPacketDescription != NULL) {
        _currentAudioStreamPacketDescription.mStartOffset = 0;
        _currentAudioStreamPacketDescription.mDataByteSize = _currentBufferList->mBuffers[0].mDataByteSize;
        _currentAudioStreamPacketDescription.mVariableFramesInPacket = 0;
        *outDataPacketDescription = &_currentAudioStreamPacketDescription;
    }
    *ioNumberDataPackets = 1;
    return noErr;
}

- (instancetype)initWithOutputFormat:(AVAudioFormat *)outputFormat
                        sourceFormat:(AVAudioFormat *)sourceFormat
                            delegate:(nonnull id<VCAudioConverterDelegate>)delegate
                       delegateQueue:(nonnull dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _outputFormat = outputFormat;
        _sourceFormat = sourceFormat;
        _delegateQueue = queue;
        _delegate = delegate;
        _converter = nil;
        
        NSUInteger bufferListSize = [self audioBufferListSizeWithBufferCount:6];
        _currentBufferList = malloc(bufferListSize);
        _feedBufferList = malloc(bufferListSize);
        
        bzero(_currentBufferList, bufferListSize);
        bzero(_feedBufferList, bufferListSize);
    }
    return self;
}

- (void)dealloc {
    if (_converter != NULL) {
        AudioConverterReset(_converter);
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
    
    if (_currentBufferList != NULL) {
        free(_currentBufferList);
        _currentBufferList = NULL;
    }
}

- (AudioConverterRef)converter {
    if (_converter != NULL) {
        return _converter;
    }
    const AudioStreamBasicDescription *sourceDesc = self.sourceFormat.streamDescription;
    const AudioStreamBasicDescription *outputDesc = self.outputFormat.streamDescription;
    
#if TARGET_IPHONE_SIMULATOR
    OSStatus ret = AudioConverterNew(sourceDesc, outputDesc, &_converter);
#else
    AudioClassDescription hardwareClassDesc = [self converterClassDescriptionWithManufacturer:kAppleHardwareAudioCodecManufacturer];
    AudioClassDescription softwareClassDesc = [self converterClassDescriptionWithManufacturer:kAppleSoftwareAudioCodecManufacturer];

    AudioClassDescription classDescs[] = {hardwareClassDesc, softwareClassDesc};
    OSStatus ret = AudioConverterNewSpecific(sourceDesc, outputDesc, sizeof(classDescs), classDescs, &_converter);
#endif
    if (ret != noErr) {
        return nil;
    }
    
    if (self.delegate &&
        [self.delegate respondsToSelector:@selector(converter:didOutputFormatDescriptor:)]) {
        [self.delegate converter:self didOutputFormatDescriptor:self.outputFormat.formatDescription];
    }
    return _converter;
}

- (AudioClassDescription)converterClassDescriptionWithManufacturer:(OSType)manufacturer {
    AudioClassDescription desc;
    if (self.sourceFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        // Encoder
        desc.mType = kAudioEncoderComponentType;
        desc.mSubType = self.outputFormat.streamDescription->mFormatID;
    } else {
        // Decoder
        desc.mType = kAudioDecoderComponentType;
        desc.mSubType = self.sourceFormat.streamDescription->mFormatID;
    }
    desc.mManufacturer = manufacturer;
    return desc;
}

- (void)setOutputFormat:(AVAudioFormat *)outputFormat {
    if ([_outputFormat isEqual:outputFormat] ||
        outputFormat == nil) {
        return;
    }
    _outputFormat = outputFormat;
    if (_converter != nil) {
        AudioConverterDispose(_converter);
    }
    _converter = nil;
}

- (void)setSourceFormat:(AVAudioFormat *)sourceFormat {
    if ([_sourceFormat isEqual:sourceFormat] ||
        sourceFormat == nil) {
        return;
    }
    _sourceFormat = sourceFormat;
    if (_converter != nil) {
        AudioConverterDispose(_converter);
    }
    _converter = nil;
}

- (void)setBitrate:(UInt32)bitrate {
    UInt32 data = bitrate;
    AudioConverterSetProperty(self.converter,
                              kAudioConverterEncodeBitRate,
                              sizeof(data),
                              &data);
}

- (UInt32)bitrate {
    UInt32 size = sizeof(UInt32);
    UInt32 data = 0;
    AudioConverterGetProperty(self.converter,
                              kAudioConverterEncodeBitRate,
                              &size, &data);
    return data;
}

- (void)setAudioConverterQuality:(UInt32)quality {
    UInt32 data = quality;
    AudioConverterSetProperty(self.converter, kAudioConverterCodecQuality, sizeof(UInt32), &data);
}

- (UInt32)audioConverterQuality {
    UInt32 size = sizeof(UInt32);
    UInt32 data = 0;
    AudioConverterGetProperty(self.converter,
                              kAudioConverterCodecQuality,
                              &size, &data);
    return data;
}

- (NSUInteger)outputAudioBufferCount {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        // Decoder
        return self.outputFormat.channelCount;
    } else {
        return 1;
    }
}

- (NSUInteger)outputMaxBufferSize {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatMPEG4AAC) {
        return 1024 * self.sourceFormat.streamDescription->mBytesPerFrame;
    } else {
        return 1024 * self.outputFormat.streamDescription->mBytesPerFrame;
    }
    
}
- (NSUInteger)outputNumberChannels {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        return 1;
    } else {
        return self.outputFormat.channelCount;
    }
}
- (NSUInteger)ioOutputDataPacketSize {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        return 1024;
    } else {
        return 1;
    }
}

- (NSUInteger)audioBufferListSizeWithBufferCount:(NSUInteger)bufferCount {
    return sizeof(AudioBufferList) + (bufferCount - 1) * sizeof(AudioBuffer);
}

- (VCSampleBuffer *)createOutputSampleBufferWithAudioBufferList:(AudioBufferList *)audioBufferList
                                                 dataPacketSize:(NSUInteger)dataPacketSize
                                                            pts:(CMTime)pts {
    CMSampleBufferRef sampleBuffer;
    CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault,
                                                    NULL,
                                                    NO,
                                                    NULL,
                                                    NULL,
                                                    self.outputFormat.formatDescription,
                                                    dataPacketSize,
                                                    pts,
                                                    _currentBufferList == NULL ? NULL : &_currentAudioStreamPacketDescription,
                                                    &sampleBuffer);
    CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                   kCFAllocatorDefault,
                                                   kCFAllocatorDefault,
                                                   0,
                                                   audioBufferList);
    return [[VCSampleBuffer alloc] initWithSampleBuffer:sampleBuffer freeWhenDone:YES];
}

#pragma mark - Convert Method

- (OSStatus)convertAudioBufferList:(const AudioBufferList *)audioBufferList
             presentationTimeStamp:(CMTime)pts {
    /// 先判断是解码还是编码
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        /// 解码
        return [self decodeAudioBufferList:audioBufferList presentationTimeStamp:pts];
    } else if (self.outputFormat.streamDescription->mFormatID == kAudioFormatMPEG4AAC) {
        /// 编码
        return [self encodeAudioBufferList:audioBufferList presentationTimeStamp:pts];
    }
    
    return -1;
}

- (OSStatus)encodeAudioBufferList:(const AudioBufferList *)audioBufferList
            presentationTimeStamp:(CMTime)pts {
    /// 1. 判断输入的Buffer是否大于一个包的大小，如果大于，需要分包，如果小于，直接送Encoder
    self.feedBufferList->mNumberBuffers = audioBufferList->mNumberBuffers;
    for (int i = 0; i < self.feedBufferList->mNumberBuffers; ++i) {
        self.feedBufferList->mBuffers[i].mNumberChannels = audioBufferList->mBuffers[i].mNumberChannels;
        if (self.feedBufferList->mBuffers[i].mDataByteSize > 0) {
            /// data copy
            NSInteger dataSize = self.feedBufferList->mBuffers[i].mDataByteSize + audioBufferList->mBuffers[i].mDataByteSize;
            uint8_t *newBuffer = (uint8_t *)malloc(dataSize);
            memcpy(newBuffer, self.feedBufferList->mBuffers[i].mData, self.feedBufferList->mBuffers[i].mDataByteSize);
            memcpy(newBuffer + self.feedBufferList->mBuffers[i].mDataByteSize, audioBufferList->mBuffers[i].mData, audioBufferList->mBuffers[i].mDataByteSize);
            
            free(self.feedBufferList->mBuffers[i].mData);
            self.feedBufferList->mBuffers[i].mData = newBuffer;
            self.feedBufferList->mBuffers[i].mDataByteSize = (UInt32)dataSize;
            self.feedBufferList->mBuffers[i].mNumberChannels = audioBufferList->mBuffers[i].mNumberChannels;
        } else {
            NSInteger dataSize = audioBufferList->mBuffers[i].mDataByteSize;
            uint8_t *newBuffer = (uint8_t *)malloc(dataSize);
            memcpy(newBuffer, audioBufferList->mBuffers[i].mData, dataSize);
            
            self.feedBufferList->mBuffers[i].mData = newBuffer;
            self.feedBufferList->mBuffers[i].mDataByteSize = (UInt32)dataSize;
            self.feedBufferList->mBuffers[i].mNumberChannels = audioBufferList->mBuffers[i].mNumberChannels;
        }
    }
    
    /// 2. 分包调用
    UInt32 outputMaxBufferSize = (UInt32)self.outputMaxBufferSize;
    UInt32 ioOutputDataPacketSize = (UInt32)self.ioOutputDataPacketSize;
    
    NSInteger splitCount = self.feedBufferList->mBuffers[0].mDataByteSize / outputMaxBufferSize;
    NSInteger restSize = self.feedBufferList->mBuffers[0].mDataByteSize % outputMaxBufferSize;
    
    /// splitCount 为循环次数
    for (int i = 0; i < splitCount; ++i) {
        AudioBufferList *outputBufferList = (AudioBufferList *)malloc([self audioBufferListSizeWithBufferCount:self.outputFormat.channelCount]);
        _currentBufferList->mNumberBuffers = self.feedBufferList->mNumberBuffers;
        outputBufferList->mNumberBuffers = (UInt32)self.outputAudioBufferCount;
        for (int j = 0; j < self.feedBufferList->mNumberBuffers; ++j) {
            
            _currentBufferList->mBuffers[j].mData = malloc(outputMaxBufferSize);
            uint8_t *p = self.feedBufferList->mBuffers[j].mData;
            memcpy(_currentBufferList->mBuffers[j].mData, p + i * outputMaxBufferSize, outputMaxBufferSize);
            _currentBufferList->mBuffers[j].mNumberChannels = self.feedBufferList->mBuffers[j].mNumberChannels;
            _currentBufferList->mBuffers[j].mDataByteSize = outputMaxBufferSize;
            
            outputBufferList->mBuffers[j].mNumberChannels = (UInt32)self.outputNumberChannels;
            outputBufferList->mBuffers[j].mDataByteSize = outputMaxBufferSize;
            outputBufferList->mBuffers[j].mData = malloc(outputMaxBufferSize);
        }
        
        OSStatus ret = AudioConverterFillComplexBuffer(self.converter,
                                                       audioConverterInputDataProc,
                                                       (__bridge void *)self,
                                                       &ioOutputDataPacketSize,
                                                       outputBufferList,
                                                       NULL);
        
        for (int j = 0; j < _currentBufferList->mNumberBuffers; ++j) {
            free(_currentBufferList->mBuffers[j].mData);
        }
        
        if (ret != noErr) {
            return ret;
        }

        
        VCSampleBuffer *audioBuffer = [self createOutputSampleBufferWithAudioBufferList:outputBufferList dataPacketSize:ioOutputDataPacketSize pts:pts];
        if (self.delegate &&
            [self.delegate respondsToSelector:@selector(converter:didOutputSampleBuffer:)]) {
            dispatch_async(self.delegateQueue, ^{
                [self.delegate converter:self didOutputSampleBuffer:audioBuffer];
            });
        }
    
        for (int j = 0; j < self.outputAudioBufferCount; ++j) {
            free(outputBufferList->mBuffers[j].mData);
        }
        free(outputBufferList);
    }
    
    for (int i = 0; i < self.feedBufferList->mNumberBuffers; ++i) {
        if (restSize == 0) {
            free(self.feedBufferList->mBuffers[i].mData);
            self.feedBufferList->mBuffers[i].mData = NULL;
            self.feedBufferList->mBuffers[i].mDataByteSize = 0;
        } else {
            uint8_t *p = (uint8_t *)self.feedBufferList->mBuffers[i].mData;
            memcpy(self.feedBufferList->mBuffers[i].mData, p + splitCount * outputMaxBufferSize, restSize);
            self.feedBufferList->mBuffers[i].mDataByteSize = (UInt32)restSize;
        }
    }
    
    return noErr;
}

- (OSStatus)decodeAudioBufferList:(const AudioBufferList *)audioBufferList
            presentationTimeStamp:(CMTime)pts {
    /// 2. 分包调用
    UInt32 outputMaxBufferSize = (UInt32)self.outputMaxBufferSize;
    UInt32 ioOutputDataPacketSize = (UInt32)self.ioOutputDataPacketSize;
    
    /// splitCount 为循环次数
    _currentBufferList->mNumberBuffers = audioBufferList->mNumberBuffers;
    for (int i = 0; i < audioBufferList->mNumberBuffers; ++i) {
        _currentBufferList->mBuffers[i].mData = malloc(ioOutputDataPacketSize);
        memcpy(_currentBufferList->mBuffers[i].mData, audioBufferList->mBuffers[i].mData, audioBufferList->mBuffers[i].mDataByteSize);
        _currentBufferList->mBuffers[i].mNumberChannels = audioBufferList->mBuffers[i].mNumberChannels;
        _currentBufferList->mBuffers[i].mDataByteSize = audioBufferList->mBuffers[i].mDataByteSize;
    }
    
    AudioBufferList *outputBufferList = (AudioBufferList *)malloc([self audioBufferListSizeWithBufferCount:self.outputFormat.channelCount]);
    outputBufferList->mNumberBuffers = (UInt32)self.outputAudioBufferCount;
    for (int i = 0; i < self.outputAudioBufferCount; ++i) {
        outputBufferList->mBuffers[i].mNumberChannels = (UInt32)self.outputNumberChannels;
        outputBufferList->mBuffers[i].mDataByteSize = outputMaxBufferSize;
        outputBufferList->mBuffers[i].mData = malloc(outputMaxBufferSize);
    }
    
    OSStatus ret = AudioConverterFillComplexBuffer(self.converter,
                                                   audioConverterInputDataProc,
                                                   (__bridge void *)self,
                                                   &ioOutputDataPacketSize,
                                                   outputBufferList,
                                                   NULL);
    for (int i = 0; i < _currentBufferList->mNumberBuffers; ++i) {
        free(_currentBufferList->mBuffers[i].mData);
    }
    
    if (ret != noErr) {
        return ret;
    }
    
    VCSampleBuffer *audioBuffer = [self createOutputSampleBufferWithAudioBufferList:outputBufferList dataPacketSize:ioOutputDataPacketSize pts:pts];
    if (self.delegate &&
        [self.delegate respondsToSelector:@selector(converter:didOutputSampleBuffer:)]) {
        dispatch_async(self.delegateQueue, ^{
            [self.delegate converter:self didOutputSampleBuffer:audioBuffer];
        });
    }
    
    for (int i = 0; i < self.outputAudioBufferCount; ++i) {
        free(outputBufferList->mBuffers[i].mData);
    }
    free(outputBufferList);
    return noErr;
}

- (OSStatus)convertSampleBuffer:(VCSampleBuffer *)sampleBuffer {
    if (self.converter == nil) return -1;
    OSStatus ret = [self convertAudioBufferList:sampleBuffer.audioBuffer.audioBufferList presentationTimeStamp:sampleBuffer.presentationTimeStamp];
    return ret;
}

- (void)reset {
    AudioConverterReset(self.converter);
}

@end
