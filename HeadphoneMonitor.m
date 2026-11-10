#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const UInt32 kRingCapacityFrames = 16384;
static const UInt32 kRingMask = kRingCapacityFrames - 1;

typedef enum {
    MonitorErrorInvalidDevice = -1001,
    MonitorErrorUnsupportedFormat = -1002,
    MonitorErrorSampleRateMismatch = -1003,
    MonitorErrorNoInput = -1004,
    MonitorErrorOutOfMemory = -1005,
} MonitorError;

typedef struct {
    _Atomic uint64_t inputCallbacks;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t deadlineMisses;
    _Atomic uint64_t cadenceMisses;
    _Atomic uint64_t callbackWorkNs;
    _Atomic uint64_t maxCallbackWorkNs;
    _Atomic uint64_t maxCadenceGapNs;
    _Atomic uint64_t inputDropEvents;
    _Atomic uint64_t inputDropFrames;
    _Atomic uint64_t outputUnderrunEvents;
    _Atomic uint64_t outputUnderrunFrames;
    _Atomic uint64_t driftCorrectionEvents;
    _Atomic uint64_t driftCorrectionFrames;
    _Atomic uint64_t maxRingFrames;
    _Atomic uint64_t deviceOverloads;
} AudioMetrics;

typedef struct {
    uint64_t previousHostTimeNs;
    BOOL hasPreviousHostTime;
} CallbackTiming;

typedef struct {
    float *samples;
    float *scratch;
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    UInt32 targetFrames;
    UInt32 outputFrames;
    float lastSample;
    AudioMetrics *metrics;
} AudioRing;

typedef struct {
    AudioDeviceID inputDevice;
    AudioDeviceID outputDevice;
    AudioDeviceIOProcID inputProcID;
    AudioDeviceIOProcID outputProcID;
    AudioDeviceIOProcID duplexProcID;
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    UInt32 inputBufferFrames;
    UInt32 outputBufferFrames;
    BOOL inputStarted;
    BOOL outputStarted;
    BOOL duplexStarted;
    BOOL inputOverloadListenerInstalled;
    BOOL outputOverloadListenerInstalled;
    BOOL running;
    double sampleRate;
    AudioMetrics metrics;
    CallbackTiming inputTiming;
    CallbackTiming outputTiming;
    CallbackTiming duplexTiming;
    AudioRing ring;
} MonitorEngine;

static uint64_t MonotonicNanoseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void AtomicUpdateMax(_Atomic uint64_t *target, uint64_t value) {
    uint64_t current = atomic_load_explicit(target, memory_order_relaxed);
    while (value > current &&
           !atomic_compare_exchange_weak_explicit(target, &current, value,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
    }
}

static void ResetMetrics(AudioMetrics *metrics) {
    atomic_store_explicit(&metrics->inputCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->outputCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->deadlineMisses, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->cadenceMisses, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->callbackWorkNs, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->maxCallbackWorkNs, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->maxCadenceGapNs, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->inputDropEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->inputDropFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->outputUnderrunEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->outputUnderrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->driftCorrectionEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->driftCorrectionFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->maxRingFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&metrics->deviceOverloads, 0, memory_order_relaxed);
}

static void RecordCallback(AudioMetrics *metrics,
                           CallbackTiming *timing,
                           BOOL countsInput,
                           BOOL countsOutput,
                           const AudioTimeStamp *now,
                           UInt32 frames,
                           double sampleRate,
                           uint64_t workNs) {
    if (countsInput) {
        atomic_fetch_add_explicit(&metrics->inputCallbacks, 1, memory_order_relaxed);
    }
    if (countsOutput) {
        atomic_fetch_add_explicit(&metrics->outputCallbacks, 1, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&metrics->callbackWorkNs, workNs, memory_order_relaxed);
    AtomicUpdateMax(&metrics->maxCallbackWorkNs, workNs);

    if (frames == 0 || sampleRate <= 0) {
        return;
    }
    uint64_t periodNs = (uint64_t)((double)frames * 1000000000.0 / sampleRate);
    if (periodNs > 0 && workNs > periodNs) {
        atomic_fetch_add_explicit(&metrics->deadlineMisses, 1, memory_order_relaxed);
    }

    if (now == NULL || (now->mFlags & kAudioTimeStampHostTimeValid) == 0 ||
        now->mHostTime == 0) {
        return;
    }
    uint64_t hostTimeNs = AudioConvertHostTimeToNanos(now->mHostTime);
    if (timing->hasPreviousHostTime && hostTimeNs > timing->previousHostTimeNs) {
        uint64_t gapNs = hostTimeNs - timing->previousHostTimeNs;
        AtomicUpdateMax(&metrics->maxCadenceGapNs, gapNs);
        uint64_t toleranceNs = periodNs / 2;
        if (toleranceNs < 250000) {
            toleranceNs = 250000;
        }
        if (gapNs > periodNs + toleranceNs) {
            atomic_fetch_add_explicit(&metrics->cadenceMisses, 1, memory_order_relaxed);
        }
    }
    timing->previousHostTimeNs = hostTimeNs;
    timing->hasPreviousHostTime = YES;
}

static BOOL FormatIsFloat32(const AudioStreamBasicDescription *format) {
    return format != NULL &&
           format->mFormatID == kAudioFormatLinearPCM &&
           (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
           (format->mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
           format->mBitsPerChannel == 32 &&
           format->mChannelsPerFrame > 0;
}

static OSStatus GetStreamFormat(AudioDeviceID device,
                                AudioObjectPropertyScope scope,
                                AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamFormat,
        scope,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*format);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, format);
}

static OSStatus GetBufferFrameSize(AudioDeviceID device, UInt32 *frames) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*frames);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, frames);
}

static OSStatus SetBufferFrameSize(AudioDeviceID device, UInt32 requestedFrames, UInt32 *actualFrames) {
    if (requestedFrames > 0) {
        AudioObjectPropertyAddress rangeAddress = {
            kAudioDevicePropertyBufferFrameSizeRange,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        AudioValueRange range = {0};
        UInt32 rangeSize = sizeof(range);
        OSStatus status = AudioObjectGetPropertyData(device, &rangeAddress, 0, NULL,
                                                     &rangeSize, &range);
        if (status != noErr) {
            return status;
        }

        UInt32 target = requestedFrames;
        if ((double)target < range.mMinimum) {
            target = (UInt32)ceil(range.mMinimum);
        }
        if ((double)target > range.mMaximum) {
            target = (UInt32)floor(range.mMaximum);
        }

        AudioObjectPropertyAddress sizeAddress = {
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        status = AudioObjectSetPropertyData(device, &sizeAddress, 0, NULL,
                                            sizeof(target), &target);
        if (status != noErr) {
            return status;
        }
    }

    return GetBufferFrameSize(device, actualFrames);
}

static double GetNominalSampleRate(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float64 sampleRate = 0;
    UInt32 size = sizeof(sampleRate);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &sampleRate) != noErr) {
        return 0;
    }
    return sampleRate;
}

static UInt32 FrameCountForBuffer(const AudioBuffer *buffer) {
    UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
    size_t bytesPerFrame = sizeof(float) * channels;
    return bytesPerFrame == 0 ? 0 : (UInt32)(buffer->mDataByteSize / bytesPerFrame);
}

static void ClearOutput(AudioBufferList *outputData) {
    if (outputData == NULL) {
        return;
    }
    for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
        AudioBuffer *buffer = &outputData->mBuffers[i];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static void RingPushFirstChannel(AudioRing *ring, const AudioBufferList *inputData) {
    if (inputData == NULL || inputData->mNumberBuffers == 0) {
        return;
    }

    const AudioBuffer *buffer = &inputData->mBuffers[0];
    const float *input = buffer->mData;
    UInt32 inputChannels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
    UInt32 frames = FrameCountForBuffer(buffer);
    if (input == NULL || frames == 0) {
        return;
    }

    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_acquire);
    UInt32 used = (UInt32)(write - read);
    UInt32 available = used < kRingCapacityFrames ? kRingCapacityFrames - used : 0;
    UInt32 count = frames < available ? frames : available;
    if (count < frames) {
        atomic_fetch_add_explicit(&ring->metrics->inputDropEvents, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->metrics->inputDropFrames, frames - count,
                                  memory_order_relaxed);
    }

    for (UInt32 frame = 0; frame < count; frame++) {
        ring->samples[(write + frame) & kRingMask] = input[frame * inputChannels];
    }
    atomic_store_explicit(&ring->writeFrame, write + count, memory_order_release);
    AtomicUpdateMax(&ring->metrics->maxRingFrames, used + count);
}

static void RingFillOutput(AudioRing *ring, AudioBufferList *outputData) {
    if (outputData == NULL || outputData->mNumberBuffers == 0) {
        return;
    }

    UInt32 frames = FrameCountForBuffer(&outputData->mBuffers[0]);
    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_relaxed);
    uint64_t available64 = write > read ? write - read : 0;

    UInt32 highWater = ring->targetFrames + ring->outputFrames * 2;
    if (available64 > highWater) {
        atomic_fetch_add_explicit(&ring->metrics->driftCorrectionEvents, 1,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->metrics->driftCorrectionFrames, 1,
                                  memory_order_relaxed);
        read++;
        atomic_store_explicit(&ring->readFrame, read, memory_order_release);
        available64--;
    }

    UInt32 available = available64 > UINT32_MAX ? UINT32_MAX : (UInt32)available64;
    UInt32 count = frames < available ? frames : available;
    if (count < frames) {
        atomic_fetch_add_explicit(&ring->metrics->outputUnderrunEvents, 1,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->metrics->outputUnderrunFrames, frames - count,
                                  memory_order_relaxed);
    }
    for (UInt32 frame = 0; frame < count; frame++) {
        ring->scratch[frame] = ring->samples[(read + frame) & kRingMask];
    }
    if (count > 0) {
        ring->lastSample = ring->scratch[count - 1];
    }
    atomic_store_explicit(&ring->readFrame, read + count, memory_order_release);

    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; bufferIndex++) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        float *output = buffer->mData;
        if (output == NULL) {
            continue;
        }
        UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        UInt32 bufferFrames = FrameCountForBuffer(buffer);
        for (UInt32 frame = 0; frame < bufferFrames; frame++) {
            float sample = frame < count ? ring->scratch[frame] : ring->lastSample;
            for (UInt32 channel = 0; channel < channels; channel++) {
                output[frame * channels + channel] = sample;
            }
        }
    }
}

static void CopyFirstInputChannel(const AudioBufferList *inputData, AudioBufferList *outputData) {
    if (outputData == NULL) {
        return;
    }
    if (inputData == NULL || inputData->mNumberBuffers == 0) {
        ClearOutput(outputData);
        return;
    }

    BOOL matchingBuffers = inputData->mNumberBuffers == outputData->mNumberBuffers;
    if (matchingBuffers) {
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            const AudioBuffer *inputBuffer = &inputData->mBuffers[i];
            AudioBuffer *outputBuffer = &outputData->mBuffers[i];
            if (inputBuffer->mNumberChannels != outputBuffer->mNumberChannels ||
                inputBuffer->mDataByteSize != outputBuffer->mDataByteSize ||
                inputBuffer->mData == NULL || outputBuffer->mData == NULL) {
                matchingBuffers = NO;
                break;
            }
        }
    }
    if (matchingBuffers) {
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            memcpy(outputData->mBuffers[i].mData,
                   inputData->mBuffers[i].mData,
                   outputData->mBuffers[i].mDataByteSize);
        }
        return;
    }

    const AudioBuffer *inputBuffer = &inputData->mBuffers[0];
    const float *input = inputBuffer->mData;
    UInt32 inputChannels = inputBuffer->mNumberChannels > 0 ? inputBuffer->mNumberChannels : 1;
    UInt32 inputFrames = FrameCountForBuffer(inputBuffer);
    if (input == NULL || inputFrames == 0) {
        ClearOutput(outputData);
        return;
    }

    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; bufferIndex++) {
        AudioBuffer *outputBuffer = &outputData->mBuffers[bufferIndex];
        float *output = outputBuffer->mData;
        if (output == NULL) {
            continue;
        }
        UInt32 outputChannels = outputBuffer->mNumberChannels > 0 ? outputBuffer->mNumberChannels : 1;
        UInt32 outputFrames = FrameCountForBuffer(outputBuffer);
        UInt32 count = outputFrames < inputFrames ? outputFrames : inputFrames;
        for (UInt32 frame = 0; frame < count; frame++) {
            float sample = input[frame * inputChannels];
            for (UInt32 channel = 0; channel < outputChannels; channel++) {
                output[frame * outputChannels + channel] = sample;
            }
        }
        if (count < outputFrames) {
            memset(output + count * outputChannels, 0,
                   (outputFrames - count) * outputChannels * sizeof(float));
        }
    }
}

static OSStatus DuplexIOProc(AudioObjectID device,
                             const AudioTimeStamp *now,
                             const AudioBufferList *inputData,
                             const AudioTimeStamp *inputTime,
                             AudioBufferList *outputData,
                             const AudioTimeStamp *outputTime,
                             void *clientData) {
    MonitorEngine *engine = (MonitorEngine *)clientData;
    uint64_t startNs = MonotonicNanoseconds();
    (void)device;
    (void)inputTime;
    (void)outputTime;
    CopyFirstInputChannel(inputData, outputData);
    uint64_t workNs = MonotonicNanoseconds() - startNs;
    UInt32 frames = outputData != NULL && outputData->mNumberBuffers > 0 ?
                    FrameCountForBuffer(&outputData->mBuffers[0]) : 0;
    RecordCallback(&engine->metrics, &engine->duplexTiming, YES, YES, now,
                   frames, engine->sampleRate, workNs);
    return noErr;
}

static OSStatus InputIOProc(AudioObjectID device,
                            const AudioTimeStamp *now,
                            const AudioBufferList *inputData,
                            const AudioTimeStamp *inputTime,
                            AudioBufferList *outputData,
                            const AudioTimeStamp *outputTime,
                            void *clientData) {
    MonitorEngine *engine = (MonitorEngine *)clientData;
    uint64_t startNs = MonotonicNanoseconds();
    (void)device;
    (void)inputTime;
    (void)outputData;
    (void)outputTime;
    RingPushFirstChannel(&engine->ring, inputData);
    uint64_t workNs = MonotonicNanoseconds() - startNs;
    UInt32 frames = inputData != NULL && inputData->mNumberBuffers > 0 ?
                    FrameCountForBuffer(&inputData->mBuffers[0]) : 0;
    RecordCallback(&engine->metrics, &engine->inputTiming, YES, NO, now,
                   frames, engine->sampleRate, workNs);
    return noErr;
}

static OSStatus OutputIOProc(AudioObjectID device,
                             const AudioTimeStamp *now,
                             const AudioBufferList *inputData,
                             const AudioTimeStamp *inputTime,
                             AudioBufferList *outputData,
                             const AudioTimeStamp *outputTime,
                             void *clientData) {
    MonitorEngine *engine = (MonitorEngine *)clientData;
    uint64_t startNs = MonotonicNanoseconds();
    (void)device;
    (void)inputData;
    (void)inputTime;
    (void)outputTime;
    RingFillOutput(&engine->ring, outputData);
    uint64_t workNs = MonotonicNanoseconds() - startNs;
    UInt32 frames = outputData != NULL && outputData->mNumberBuffers > 0 ?
                    FrameCountForBuffer(&outputData->mBuffers[0]) : 0;
    RecordCallback(&engine->metrics, &engine->outputTiming, NO, YES, now,
                   frames, engine->sampleRate, workNs);
    return noErr;
}

static OSStatus DeviceOverloadListener(AudioObjectID objectID,
                                       UInt32 addressCount,
                                       const AudioObjectPropertyAddress *addresses,
                                       void *clientData) {
    (void)objectID;
    MonitorEngine *engine = (MonitorEngine *)clientData;
    for (UInt32 i = 0; i < addressCount; i++) {
        if (addresses[i].mSelector == kAudioDeviceProcessorOverload) {
            atomic_fetch_add_explicit(&engine->metrics.deviceOverloads, 1,
                                      memory_order_relaxed);
        }
    }
    return noErr;
}

static void InstallOverloadListener(MonitorEngine *engine,
                                    AudioDeviceID device,
                                    BOOL isInput) {
    AudioObjectPropertyAddress address = {
        kAudioDeviceProcessorOverload,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (AudioObjectAddPropertyListener(device, &address, DeviceOverloadListener,
                                       engine) == noErr) {
        if (isInput) {
            engine->inputOverloadListenerInstalled = YES;
        } else {
            engine->outputOverloadListenerInstalled = YES;
        }
    }
}

static void RemoveOverloadListeners(MonitorEngine *engine) {
    AudioObjectPropertyAddress address = {
        kAudioDeviceProcessorOverload,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (engine->inputOverloadListenerInstalled) {
        AudioObjectRemovePropertyListener(engine->inputDevice, &address,
                                          DeviceOverloadListener, engine);
        engine->inputOverloadListenerInstalled = NO;
    }
    if (engine->outputOverloadListenerInstalled) {
        AudioObjectRemovePropertyListener(engine->outputDevice, &address,
                                          DeviceOverloadListener, engine);
        engine->outputOverloadListenerInstalled = NO;
    }
}

static void StopEngine(MonitorEngine *engine) {
    if (engine->duplexStarted) {
        AudioDeviceStop(engine->inputDevice, engine->duplexProcID);
    }
    if (engine->outputStarted) {
        AudioDeviceStop(engine->outputDevice, engine->outputProcID);
    }
    if (engine->inputStarted) {
        AudioDeviceStop(engine->inputDevice, engine->inputProcID);
    }
    if (engine->duplexProcID != NULL) {
        AudioDeviceDestroyIOProcID(engine->inputDevice, engine->duplexProcID);
    }
    if (engine->outputProcID != NULL) {
        AudioDeviceDestroyIOProcID(engine->outputDevice, engine->outputProcID);
    }
    if (engine->inputProcID != NULL) {
        AudioDeviceDestroyIOProcID(engine->inputDevice, engine->inputProcID);
    }
    RemoveOverloadListeners(engine);
    free(engine->ring.samples);
    free(engine->ring.scratch);
    engine->ring.samples = NULL;
    engine->ring.scratch = NULL;
    engine->inputProcID = NULL;
    engine->outputProcID = NULL;
    engine->duplexProcID = NULL;
    engine->inputStarted = NO;
    engine->outputStarted = NO;
    engine->duplexStarted = NO;
    engine->running = NO;
}

static OSStatus StartEngine(MonitorEngine *engine,
                            AudioDeviceID inputDevice,
                            AudioDeviceID outputDevice,
                            UInt32 requestedBufferFrames) {
    if (engine == NULL || inputDevice == kAudioObjectUnknown || outputDevice == kAudioObjectUnknown) {
        return MonitorErrorInvalidDevice;
    }

    StopEngine(engine);
    memset(engine, 0, sizeof(*engine));
    engine->inputDevice = inputDevice;
    engine->outputDevice = outputDevice;
    ResetMetrics(&engine->metrics);

    double inputRate = GetNominalSampleRate(inputDevice);
    double outputRate = GetNominalSampleRate(outputDevice);
    if (inputRate <= 0 || outputRate <= 0 || fabs(inputRate - outputRate) > 0.5) {
        return MonitorErrorSampleRateMismatch;
    }
    engine->sampleRate = inputRate;

    OSStatus status = SetBufferFrameSize(inputDevice, requestedBufferFrames,
                                         &engine->inputBufferFrames);
    if (status != noErr) {
        return status;
    }
    status = SetBufferFrameSize(outputDevice, requestedBufferFrames,
                                &engine->outputBufferFrames);
    if (status != noErr) {
        return status;
    }

    status = GetStreamFormat(inputDevice, kAudioObjectPropertyScopeInput, &engine->inputFormat);
    if (status != noErr || !FormatIsFloat32(&engine->inputFormat)) {
        return MonitorErrorUnsupportedFormat;
    }
    status = GetStreamFormat(outputDevice, kAudioObjectPropertyScopeOutput, &engine->outputFormat);
    if (status != noErr || !FormatIsFloat32(&engine->outputFormat)) {
        return MonitorErrorUnsupportedFormat;
    }

    if (inputDevice == outputDevice) {
        InstallOverloadListener(engine, inputDevice, YES);
        status = AudioDeviceCreateIOProcID(inputDevice, DuplexIOProc, engine,
                                           &engine->duplexProcID);
        if (status != noErr) {
            return status;
        }
        status = AudioDeviceStart(inputDevice, engine->duplexProcID);
        if (status != noErr) {
            AudioDeviceDestroyIOProcID(inputDevice, engine->duplexProcID);
            engine->duplexProcID = NULL;
            return status;
        }
        engine->duplexStarted = YES;
        engine->running = YES;
        return noErr;
    }

    engine->ring.samples = calloc(kRingCapacityFrames, sizeof(float));
    engine->ring.scratch = calloc(kRingCapacityFrames, sizeof(float));
    if (engine->ring.samples == NULL || engine->ring.scratch == NULL) {
        free(engine->ring.samples);
        free(engine->ring.scratch);
        engine->ring.samples = NULL;
        engine->ring.scratch = NULL;
        return MonitorErrorOutOfMemory;
    }
    engine->ring.targetFrames = engine->outputBufferFrames * 2;
    if (engine->ring.targetFrames < 2) {
        engine->ring.targetFrames = 2;
    }
    engine->ring.outputFrames = engine->outputBufferFrames;
    engine->ring.metrics = &engine->metrics;
    atomic_init(&engine->ring.writeFrame, 0);
    atomic_init(&engine->ring.readFrame, 0);
    InstallOverloadListener(engine, inputDevice, YES);
    InstallOverloadListener(engine, outputDevice, NO);

    status = AudioDeviceCreateIOProcID(inputDevice, InputIOProc, engine,
                                       &engine->inputProcID);
    if (status != noErr) {
        StopEngine(engine);
        return status;
    }
    status = AudioDeviceCreateIOProcID(outputDevice, OutputIOProc, engine,
                                       &engine->outputProcID);
    if (status != noErr) {
        StopEngine(engine);
        return status;
    }

    status = AudioDeviceStart(inputDevice, engine->inputProcID);
    if (status != noErr) {
        StopEngine(engine);
        return status;
    }
    engine->inputStarted = YES;

    for (UInt32 attempt = 0; attempt < 40; attempt++) {
        uint64_t write = atomic_load_explicit(&engine->ring.writeFrame, memory_order_acquire);
        uint64_t read = atomic_load_explicit(&engine->ring.readFrame, memory_order_relaxed);
        if (write - read >= engine->ring.targetFrames) {
            break;
        }
        usleep(5000);
    }
    uint64_t primedFrames = atomic_load_explicit(&engine->ring.writeFrame, memory_order_acquire) -
                            atomic_load_explicit(&engine->ring.readFrame, memory_order_relaxed);
    if (primedFrames == 0) {
        StopEngine(engine);
        return MonitorErrorNoInput;
    }

    status = AudioDeviceStart(outputDevice, engine->outputProcID);
    if (status != noErr) {
        StopEngine(engine);
        return status;
    }
    engine->outputStarted = YES;
    engine->running = YES;
    return noErr;
}

static OSStatus GetDefaultDevice(AudioObjectPropertySelector selector, AudioDeviceID *device) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*device);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, device);
}

static UInt32 DeviceChannelCount(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) {
        return 0;
    }
    AudioBufferList *bufferList = malloc(size);
    if (bufferList == NULL) {
        return 0;
    }
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, bufferList) == noErr) {
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            channels += bufferList->mBuffers[i].mNumberChannels;
        }
    }
    free(bufferList);
    return channels;
}

static NSString *DeviceName(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr ||
        name == NULL) {
        return @"Unknown Device";
    }
    return CFBridgingRelease(name);
}

static NSArray<NSNumber *> *DeviceIDs(AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL,
                                       &size) != noErr) {
        return @[];
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                   &size, data.mutableBytes) != noErr) {
        return @[];
    }

    NSMutableArray<NSNumber *> *devices = [NSMutableArray array];
    AudioDeviceID *deviceIDs = data.mutableBytes;
    NSUInteger count = size / sizeof(AudioDeviceID);
    for (NSUInteger i = 0; i < count; i++) {
        if (DeviceChannelCount(deviceIDs[i], scope) > 0) {
            [devices addObject:@(deviceIDs[i])];
        }
    }
    return devices;
}

static NSString *StartErrorDescription(OSStatus status) {
    switch (status) {
        case MonitorErrorInvalidDevice:
            return @"Select a valid input and output device.";
        case MonitorErrorUnsupportedFormat:
            return @"The selected devices must expose 32-bit floating-point PCM streams.";
        case MonitorErrorSampleRateMismatch:
            return @"Input and output sample rates must match. Set both devices to the same rate in Audio MIDI Setup; this app does not resample.";
        case MonitorErrorNoInput:
            return @"No microphone data arrived. Check microphone permission and the selected input device.";
        case MonitorErrorOutOfMemory:
            return @"Could not allocate the audio bridge buffer.";
        default:
            return [NSString stringWithFormat:@"CoreAudio error %d.", (int)status];
    }
}

typedef struct {
    uint64_t inputCallbacks;
    uint64_t outputCallbacks;
    uint64_t deadlineMisses;
    uint64_t cadenceMisses;
    uint64_t callbackWorkNs;
    uint64_t maxCallbackWorkNs;
    uint64_t maxCadenceGapNs;
    uint64_t inputDropEvents;
    uint64_t inputDropFrames;
    uint64_t outputUnderrunEvents;
    uint64_t outputUnderrunFrames;
    uint64_t driftCorrectionEvents;
    uint64_t driftCorrectionFrames;
    uint64_t maxRingFrames;
    uint64_t deviceOverloads;
    uint64_t ringFrames;
} MetricsSnapshot;

static MetricsSnapshot SnapshotMetrics(const MonitorEngine *engine) {
    MetricsSnapshot snapshot = {
        .inputCallbacks = atomic_load_explicit(&engine->metrics.inputCallbacks,
                                               memory_order_relaxed),
        .outputCallbacks = atomic_load_explicit(&engine->metrics.outputCallbacks,
                                                memory_order_relaxed),
        .deadlineMisses = atomic_load_explicit(&engine->metrics.deadlineMisses,
                                               memory_order_relaxed),
        .cadenceMisses = atomic_load_explicit(&engine->metrics.cadenceMisses,
                                              memory_order_relaxed),
        .callbackWorkNs = atomic_load_explicit(&engine->metrics.callbackWorkNs,
                                               memory_order_relaxed),
        .maxCallbackWorkNs = atomic_load_explicit(&engine->metrics.maxCallbackWorkNs,
                                                   memory_order_relaxed),
        .maxCadenceGapNs = atomic_load_explicit(&engine->metrics.maxCadenceGapNs,
                                                 memory_order_relaxed),
        .inputDropEvents = atomic_load_explicit(&engine->metrics.inputDropEvents,
                                                memory_order_relaxed),
        .inputDropFrames = atomic_load_explicit(&engine->metrics.inputDropFrames,
                                                memory_order_relaxed),
        .outputUnderrunEvents = atomic_load_explicit(&engine->metrics.outputUnderrunEvents,
                                                      memory_order_relaxed),
        .outputUnderrunFrames = atomic_load_explicit(&engine->metrics.outputUnderrunFrames,
                                                      memory_order_relaxed),
        .driftCorrectionEvents = atomic_load_explicit(&engine->metrics.driftCorrectionEvents,
                                                       memory_order_relaxed),
        .driftCorrectionFrames = atomic_load_explicit(&engine->metrics.driftCorrectionFrames,
                                                       memory_order_relaxed),
        .maxRingFrames = atomic_load_explicit(&engine->metrics.maxRingFrames,
                                              memory_order_relaxed),
        .deviceOverloads = atomic_load_explicit(&engine->metrics.deviceOverloads,
                                                memory_order_relaxed),
    };
    if (engine->ring.samples != NULL) {
        uint64_t write = atomic_load_explicit(&engine->ring.writeFrame, memory_order_acquire);
        uint64_t read = atomic_load_explicit(&engine->ring.readFrame, memory_order_relaxed);
        snapshot.ringFrames = write > read ? write - read : 0;
    }
    return snapshot;
}

typedef NS_ENUM(NSInteger, PerformanceMenuTag) {
    PerformanceStatusTag = 2001,
    PerformanceModeTag,
    PerformanceFormatTag,
    PerformanceCallbacksTag,
    PerformanceWorkTag,
    PerformanceDeadlinesTag,
    PerformanceCadenceTag,
    PerformanceBridgeTag,
    PerformanceUnderrunsTag,
    PerformanceInputDropsTag,
    PerformanceDriftTag,
    PerformanceOverloadsTag,
};

typedef NS_ENUM(NSInteger, PerformanceSeverity) {
    PerformanceSeverityInfo = 0,
    PerformanceSeverityOK,
    PerformanceSeverityWarning,
    PerformanceSeverityError,
};

static NSString *PerformanceSeverityLabel(PerformanceSeverity severity) {
    switch (severity) {
        case PerformanceSeverityWarning:
            return @"WARN ";
        case PerformanceSeverityError:
            return @"ERROR";
        case PerformanceSeverityOK:
            return @"OK   ";
        case PerformanceSeverityInfo:
        default:
            return @"INFO ";
    }
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, assign) AudioDeviceID inputDevice;
@property(nonatomic, assign) AudioDeviceID outputDevice;
@property(nonatomic, assign) UInt32 requestedBufferFrames;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, strong) NSTimer *metricsTimer;
@property(nonatomic, strong) NSMenuItem *performanceRoot;
@property(nonatomic, strong) NSMenu *performanceSubmenu;
@property(nonatomic, assign) uint64_t previousInputCallbacks;
@property(nonatomic, assign) uint64_t previousOutputCallbacks;
@property(nonatomic, assign) uint64_t previousMetricsTimeNs;
@end

@implementation AppDelegate {
    MonitorEngine _engine;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"mic.fill"
                                             accessibilityDescription:@"Headphone Monitor"];
    self.statusItem.button.image.template = YES;

    AudioDeviceID input = kAudioObjectUnknown;
    AudioDeviceID output = kAudioObjectUnknown;
    GetDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &input);
    GetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, &output);
    self.inputDevice = input;
    self.outputDevice = output;
    self.requestedBufferFrames = 32;
    self.running = NO;

    [self rebuildMenu];
    __weak typeof(self) weakSelf = self;
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf updatePerformanceDisplay];
    }];
    [self resetMetricsBaseline];
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Headphone Monitor"];

    NSString *statusTitle = self.running ? @"Monitoring Active" : @"Monitoring Stopped";
    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:statusTitle action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];

    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:(self.running ? @"Stop Monitoring" : @"Start Monitoring")
                                                   action:@selector(toggleMonitoring:)
                                            keyEquivalent:@""];
    toggle.target = self;
    [menu addItem:toggle];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self deviceMenuItemWithTitle:@"Input Device" scope:kAudioObjectPropertyScopeInput]];
    [menu addItem:[self deviceMenuItemWithTitle:@"Output Device" scope:kAudioObjectPropertyScopeOutput]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self bufferMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self performanceMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About Headphone Monitor"
                                                  action:@selector(showAbout:)
                                           keyEquivalent:@""];
    about.target = self;
    [menu addItem:about];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                 action:@selector(quit:)
                                          keyEquivalent:@""];
    quit.target = self;
    [menu addItem:quit];

    self.menu = menu;
    self.statusItem.menu = menu;
}

- (NSMenuItem *)deviceMenuItemWithTitle:(NSString *)title scope:(AudioObjectPropertyScope)scope {
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
    AudioDeviceID selected = scope == kAudioObjectPropertyScopeInput ? self.inputDevice : self.outputDevice;
    BOOL foundSelected = NO;

    for (NSNumber *number in DeviceIDs(scope)) {
        AudioDeviceID device = number.unsignedIntValue;
        double sampleRate = GetNominalSampleRate(device);
        NSString *name = DeviceName(device);
        NSString *label = [NSString stringWithFormat:@"%@ (%.1f kHz)", name, sampleRate / 1000.0];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label
                                                     action:(scope == kAudioObjectPropertyScopeInput ?
                                                             @selector(selectInput:) : @selector(selectOutput:))
                                              keyEquivalent:@""];
        item.target = self;
        item.representedObject = number;
        item.state = device == selected ? NSControlStateValueOn : NSControlStateValueOff;
        foundSelected = foundSelected || device == selected;
        [submenu addItem:item];
    }

    if (!foundSelected) {
        AudioDeviceID fallback = kAudioObjectUnknown;
        GetDefaultDevice(scope == kAudioObjectPropertyScopeInput ?
                             kAudioHardwarePropertyDefaultInputDevice :
                             kAudioHardwarePropertyDefaultOutputDevice,
                         &fallback);
        if (scope == kAudioObjectPropertyScopeInput) {
            self.inputDevice = fallback;
        } else {
            self.outputDevice = fallback;
        }
    }
    root.submenu = submenu;
    return root;
}

- (NSMenuItem *)performanceMetricItemWithTitle:(NSString *)title tag:(PerformanceMenuTag)tag {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    item.tag = tag;
    return item;
}

- (NSMenuItem *)performanceMenuItem {
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Performance" action:nil keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Performance"];

    [submenu addItem:[self performanceMetricItemWithTitle:@"INFO  Status: unavailable"
                                                       tag:PerformanceStatusTag]];
    [submenu addItem:[NSMenuItem separatorItem]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"No audio session data"
                                                       tag:PerformanceModeTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Format: unavailable"
                                                       tag:PerformanceFormatTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Callbacks: unavailable"
                                                       tag:PerformanceCallbacksTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Callback work: unavailable"
                                                       tag:PerformanceWorkTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Deadline misses: unavailable"
                                                       tag:PerformanceDeadlinesTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Cadence misses: unavailable"
                                                       tag:PerformanceCadenceTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Bridge: unavailable"
                                                       tag:PerformanceBridgeTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Output underruns: unavailable"
                                                       tag:PerformanceUnderrunsTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Input drops: unavailable"
                                                       tag:PerformanceInputDropsTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"Drift corrections: unavailable"
                                                       tag:PerformanceDriftTag]];
    [submenu addItem:[self performanceMetricItemWithTitle:@"CoreAudio overloads: unavailable"
                                                       tag:PerformanceOverloadsTag]];
    [submenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *reset = [[NSMenuItem alloc] initWithTitle:@"Reset Counters"
                                                  action:@selector(resetMetrics:)
                                           keyEquivalent:@""];
    reset.target = self;
    [submenu addItem:reset];

    root.submenu = submenu;
    self.performanceRoot = root;
    self.performanceSubmenu = submenu;
    return root;
}

- (void)setPerformanceTitle:(NSString *)title
                     forTag:(PerformanceMenuTag)tag
                   severity:(PerformanceSeverity)severity {
    NSMenuItem *item = [self.performanceSubmenu itemWithTag:tag];
    item.title = [NSString stringWithFormat:@"%@  %@", PerformanceSeverityLabel(severity), title];
}

- (void)setPerformanceTitle:(NSString *)title forTag:(PerformanceMenuTag)tag {
    [self setPerformanceTitle:title forTag:tag severity:PerformanceSeverityInfo];
}

- (void)resetMetricsBaseline {
    MetricsSnapshot snapshot = SnapshotMetrics(&_engine);
    self.previousInputCallbacks = snapshot.inputCallbacks;
    self.previousOutputCallbacks = snapshot.outputCallbacks;
    self.previousMetricsTimeNs = MonotonicNanoseconds();
}

- (void)updatePerformanceDisplay {
    MetricsSnapshot snapshot = SnapshotMetrics(&_engine);
    uint64_t nowNs = MonotonicNanoseconds();
    double elapsedSeconds = self.previousMetricsTimeNs > 0 && nowNs > self.previousMetricsTimeNs ?
                            (double)(nowNs - self.previousMetricsTimeNs) / 1000000000.0 : 0;
    double inputRate = 0;
    double outputRate = 0;
    if (elapsedSeconds > 0) {
        if (snapshot.inputCallbacks >= self.previousInputCallbacks) {
            inputRate = (double)(snapshot.inputCallbacks - self.previousInputCallbacks) / elapsedSeconds;
        }
        if (snapshot.outputCallbacks >= self.previousOutputCallbacks) {
            outputRate = (double)(snapshot.outputCallbacks - self.previousOutputCallbacks) / elapsedSeconds;
        }
    }
    self.previousInputCallbacks = snapshot.inputCallbacks;
    self.previousOutputCallbacks = snapshot.outputCallbacks;
    self.previousMetricsTimeNs = nowNs;

    uint64_t callbacks = snapshot.inputCallbacks + snapshot.outputCallbacks;
    if (callbacks == 0) {
        [self setPerformanceTitle:@"Status: no audio session data"
                           forTag:PerformanceStatusTag
                         severity:PerformanceSeverityInfo];
        [self setPerformanceTitle:@"No audio session data" forTag:PerformanceModeTag];
        [self setPerformanceTitle:@"Format: unavailable" forTag:PerformanceFormatTag];
        [self setPerformanceTitle:@"Callbacks: unavailable" forTag:PerformanceCallbacksTag];
        [self setPerformanceTitle:@"Callback work: unavailable" forTag:PerformanceWorkTag];
        [self setPerformanceTitle:@"Deadline misses: unavailable" forTag:PerformanceDeadlinesTag];
        [self setPerformanceTitle:@"Cadence misses: unavailable" forTag:PerformanceCadenceTag];
        [self setPerformanceTitle:@"Bridge: unavailable" forTag:PerformanceBridgeTag];
        [self setPerformanceTitle:@"Output underruns: unavailable" forTag:PerformanceUnderrunsTag];
        [self setPerformanceTitle:@"Input drops: unavailable" forTag:PerformanceInputDropsTag];
        [self setPerformanceTitle:@"Drift corrections: unavailable" forTag:PerformanceDriftTag];
        [self setPerformanceTitle:@"CoreAudio overloads: unavailable" forTag:PerformanceOverloadsTag];
        self.performanceRoot.title = @"Performance";
        self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"mic.fill"
                                                 accessibilityDescription:@"Headphone Monitor"];
        self.statusItem.button.image.template = YES;
        self.statusItem.button.contentTintColor = nil;
        self.statusItem.button.toolTip = @"Headphone Monitor";
        return;
    }

    NSUInteger errorCount = 0;
    NSUInteger warningCount = 0;
    BOOL direct = _engine.inputDevice == _engine.outputDevice;
    [self setPerformanceTitle:(direct ? @"Mode: direct device callback" : @"Mode: bridged devices")
                       forTag:PerformanceModeTag];
    [self setPerformanceTitle:[NSString stringWithFormat:@"Format: %.1f kHz, %u in / %u out frames",
                                                         _engine.sampleRate / 1000.0,
                                                         _engine.inputBufferFrames,
                                                         _engine.outputBufferFrames]
                       forTag:PerformanceFormatTag];

    PerformanceSeverity callbackSeverity = PerformanceSeverityInfo;
    NSString *callbackTitle = @"Callbacks: stopped";
    if (self.running && _engine.sampleRate > 0 && _engine.inputBufferFrames > 0 &&
        _engine.outputBufferFrames > 0) {
        double expectedInputRate = _engine.sampleRate / _engine.inputBufferFrames;
        double expectedOutputRate = _engine.sampleRate / _engine.outputBufferFrames;
        double inputRatio = expectedInputRate > 0 ? inputRate / expectedInputRate : 1;
        double outputRatio = expectedOutputRate > 0 ? outputRate / expectedOutputRate : 1;
        double minimumRatio = inputRatio < outputRatio ? inputRatio : outputRatio;
        callbackSeverity = minimumRatio < 0.5 ? PerformanceSeverityError :
                           minimumRatio < 0.8 ? PerformanceSeverityWarning :
                           PerformanceSeverityOK;
        callbackTitle = [NSString stringWithFormat:@"Callbacks: %.0f/s input, %.0f/s output",
                                                    inputRate, outputRate];
    }
    [self setPerformanceTitle:callbackTitle forTag:PerformanceCallbacksTag severity:callbackSeverity];
    if (callbackSeverity == PerformanceSeverityError) {
        errorCount++;
    } else if (callbackSeverity == PerformanceSeverityWarning) {
        warningCount++;
    }

    double averageWorkMs = callbacks > 0 ?
                           ((double)snapshot.callbackWorkNs / (double)callbacks) / 1000000.0 : 0;
    double maximumWorkMs = (double)snapshot.maxCallbackWorkNs / 1000000.0;
    double inputBudgetMs = _engine.sampleRate > 0 ?
                           (double)_engine.inputBufferFrames * 1000.0 / _engine.sampleRate : 0;
    double outputBudgetMs = _engine.sampleRate > 0 ?
                            (double)_engine.outputBufferFrames * 1000.0 / _engine.sampleRate : 0;
    double shortestBudgetMs = inputBudgetMs;
    if (outputBudgetMs > 0 && (shortestBudgetMs <= 0 || outputBudgetMs < shortestBudgetMs)) {
        shortestBudgetMs = outputBudgetMs;
    }
    double workRatio = shortestBudgetMs > 0 ? maximumWorkMs / shortestBudgetMs : 0;
    PerformanceSeverity workSeverity = workRatio >= 1.0 ? PerformanceSeverityError :
                                       workRatio >= 0.75 ? PerformanceSeverityWarning :
                                       PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Callback work: %.3f ms avg, %.3f ms max",
                                                         averageWorkMs, maximumWorkMs]
                       forTag:PerformanceWorkTag
                     severity:workSeverity];
    if (workSeverity == PerformanceSeverityError) {
        errorCount++;
    } else if (workSeverity == PerformanceSeverityWarning) {
        warningCount++;
    }

    PerformanceSeverity deadlineSeverity = snapshot.deadlineMisses > 0 ?
                                           PerformanceSeverityError : PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Deadline misses: %llu, budget %.3f / %.3f ms",
                                                         (unsigned long long)snapshot.deadlineMisses,
                                                         inputBudgetMs, outputBudgetMs]
                       forTag:PerformanceDeadlinesTag
                     severity:deadlineSeverity];
    if (deadlineSeverity == PerformanceSeverityError) {
        errorCount++;
    }

    PerformanceSeverity cadenceSeverity = snapshot.cadenceMisses == 0 ? PerformanceSeverityOK :
        (callbacks > 0 && snapshot.cadenceMisses * 1000 >= callbacks) ? PerformanceSeverityError :
        PerformanceSeverityWarning;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Cadence misses: %llu, max gap %.3f ms",
                                                         (unsigned long long)snapshot.cadenceMisses,
                                                         (double)snapshot.maxCadenceGapNs / 1000000.0]
                       forTag:PerformanceCadenceTag
                     severity:cadenceSeverity];
    if (cadenceSeverity == PerformanceSeverityError) {
        errorCount++;
    } else if (cadenceSeverity == PerformanceSeverityWarning) {
        warningCount++;
    }

    if (!direct && self.running && _engine.ring.samples != NULL) {
        double fillMs = _engine.sampleRate > 0 ?
                        (double)snapshot.ringFrames * 1000.0 / _engine.sampleRate : 0;
        double maxFillMs = _engine.sampleRate > 0 ?
                           (double)snapshot.maxRingFrames * 1000.0 / _engine.sampleRate : 0;
        PerformanceSeverity bridgeSeverity = snapshot.ringFrames == 0 ? PerformanceSeverityError :
                                             snapshot.ringFrames < _engine.ring.targetFrames ?
                                             PerformanceSeverityWarning : PerformanceSeverityOK;
        [self setPerformanceTitle:[NSString stringWithFormat:@"Bridge: %llu frames (%.2f ms), max %.2f ms",
                                                             (unsigned long long)snapshot.ringFrames,
                                                             fillMs, maxFillMs]
                           forTag:PerformanceBridgeTag
                         severity:bridgeSeverity];
        if (bridgeSeverity == PerformanceSeverityError) {
            errorCount++;
        } else if (bridgeSeverity == PerformanceSeverityWarning) {
            warningCount++;
        }
    } else {
        [self setPerformanceTitle:(direct ? @"Bridge: not used (direct callback)" : @"Bridge: stopped")
                           forTag:PerformanceBridgeTag
                         severity:PerformanceSeverityInfo];
    }

    PerformanceSeverity underrunSeverity = snapshot.outputUnderrunEvents > 0 ?
                                           PerformanceSeverityError : PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Output underruns: %llu events / %llu frames",
                                                         (unsigned long long)snapshot.outputUnderrunEvents,
                                                         (unsigned long long)snapshot.outputUnderrunFrames]
                       forTag:PerformanceUnderrunsTag
                     severity:underrunSeverity];
    if (underrunSeverity == PerformanceSeverityError) {
        errorCount++;
    }

    PerformanceSeverity inputDropSeverity = snapshot.inputDropEvents > 0 ?
                                            PerformanceSeverityError : PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Input drops: %llu events / %llu frames",
                                                         (unsigned long long)snapshot.inputDropEvents,
                                                         (unsigned long long)snapshot.inputDropFrames]
                       forTag:PerformanceInputDropsTag
                     severity:inputDropSeverity];
    if (inputDropSeverity == PerformanceSeverityError) {
        errorCount++;
    }

    PerformanceSeverity driftSeverity = snapshot.driftCorrectionEvents > 0 ?
                                        PerformanceSeverityWarning : PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"Drift corrections: %llu events / %llu frames",
                                                         (unsigned long long)snapshot.driftCorrectionEvents,
                                                         (unsigned long long)snapshot.driftCorrectionFrames]
                       forTag:PerformanceDriftTag
                     severity:driftSeverity];
    if (driftSeverity == PerformanceSeverityWarning) {
        warningCount++;
    }

    PerformanceSeverity overloadSeverity = snapshot.deviceOverloads > 0 ?
                                           PerformanceSeverityError : PerformanceSeverityOK;
    [self setPerformanceTitle:[NSString stringWithFormat:@"CoreAudio overloads: %llu",
                                                         (unsigned long long)snapshot.deviceOverloads]
                       forTag:PerformanceOverloadsTag
                     severity:overloadSeverity];
    if (overloadSeverity == PerformanceSeverityError) {
        errorCount++;
    }

    PerformanceSeverity overallSeverity = errorCount > 0 ? PerformanceSeverityError :
                                           warningCount > 0 ? PerformanceSeverityWarning :
                                           PerformanceSeverityOK;
    if (overallSeverity == PerformanceSeverityError) {
        [self setPerformanceTitle:[NSString stringWithFormat:@"Status: %lu errors, %lu warnings",
                                                             (unsigned long)errorCount,
                                                             (unsigned long)warningCount]
                           forTag:PerformanceStatusTag
                         severity:PerformanceSeverityError];
    } else if (overallSeverity == PerformanceSeverityWarning) {
        [self setPerformanceTitle:[NSString stringWithFormat:@"Status: %lu warnings",
                                                             (unsigned long)warningCount]
                           forTag:PerformanceStatusTag
                         severity:PerformanceSeverityWarning];
    } else {
        [self setPerformanceTitle:@"Status: healthy" forTag:PerformanceStatusTag
                        severity:PerformanceSeverityOK];
    }

    self.performanceRoot.title = overallSeverity == PerformanceSeverityError ? @"Performance: ERROR" :
                                 overallSeverity == PerformanceSeverityWarning ? @"Performance: WARN" :
                                 @"Performance";
    NSString *symbol = self.running && overallSeverity == PerformanceSeverityError ? @"xmark.octagon.fill" :
                       self.running && overallSeverity == PerformanceSeverityWarning ? @"exclamationmark.triangle.fill" :
                       @"mic.fill";
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol
                                             accessibilityDescription:@"Headphone Monitor"];
    self.statusItem.button.image.template = YES;
    self.statusItem.button.contentTintColor =
        self.running && overallSeverity == PerformanceSeverityError ? [NSColor systemRedColor] :
        self.running && overallSeverity == PerformanceSeverityWarning ? [NSColor systemOrangeColor] : nil;
    self.statusItem.button.toolTip = overallSeverity == PerformanceSeverityError ?
        [NSString stringWithFormat:@"Headphone Monitor: %lu performance errors",
                                   (unsigned long)errorCount] :
        overallSeverity == PerformanceSeverityWarning ?
        [NSString stringWithFormat:@"Headphone Monitor: %lu performance warnings",
                                   (unsigned long)warningCount] :
        @"Headphone Monitor: counters healthy";
}

- (void)resetMetrics:(NSMenuItem *)sender {
    (void)sender;
    ResetMetrics(&_engine.metrics);
    [self resetMetricsBaseline];
    [self updatePerformanceDisplay];
}

- (NSMenuItem *)bufferMenuItem {
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Buffer Size" action:nil keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Buffer Size"];
    NSArray<NSNumber *> *sizes = @[@0, @16, @32, @64, @128, @256];
    for (NSNumber *number in sizes) {
        UInt32 frames = number.unsignedIntValue;
        NSString *label = frames == 0 ? @"Device Default" : [NSString stringWithFormat:@"%u frames", frames];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label
                                                     action:@selector(selectBufferSize:)
                                              keyEquivalent:@""];
        item.target = self;
        item.representedObject = number;
        item.state = frames == self.requestedBufferFrames ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
    root.submenu = submenu;
    return root;
}

- (void)restartIfNeeded {
    if (!self.running) {
        return;
    }
    StopEngine(&_engine);
    self.running = NO;
    [self startMonitoring];
}

- (void)selectInput:(NSMenuItem *)sender {
    self.inputDevice = [sender.representedObject unsignedIntValue];
    [self restartIfNeeded];
    [self rebuildMenu];
}

- (void)selectOutput:(NSMenuItem *)sender {
    self.outputDevice = [sender.representedObject unsignedIntValue];
    [self restartIfNeeded];
    [self rebuildMenu];
}

- (void)selectBufferSize:(NSMenuItem *)sender {
    self.requestedBufferFrames = [sender.representedObject unsignedIntValue];
    [self restartIfNeeded];
    [self rebuildMenu];
}

- (void)startMonitoring {
    OSStatus status = StartEngine(&_engine, self.inputDevice, self.outputDevice,
                                  self.requestedBufferFrames);
    if (status != noErr) {
        self.running = NO;
        [self rebuildMenu];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could Not Start Monitoring";
        alert.informativeText = StartErrorDescription(status);
        alert.alertStyle = NSAlertStyleWarning;
        [alert runModal];
        return;
    }
    self.running = YES;
    [self resetMetricsBaseline];
    [self rebuildMenu];
    [self updatePerformanceDisplay];
}

- (void)stopMonitoring {
    StopEngine(&_engine);
    self.running = NO;
    [self rebuildMenu];
    [self updatePerformanceDisplay];
}

- (void)toggleMonitoring:(NSMenuItem *)sender {
    (void)sender;
    if (self.running) {
        [self stopMonitoring];
    } else {
        [self startMonitoring];
    }
}

- (void)showAbout:(NSMenuItem *)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Headphone Monitor";
    alert.informativeText = @"Direct CoreAudio HAL monitoring without app-level recording, resampling, gain, EQ, or voice processing.";
    alert.alertStyle = NSAlertStyleInformational;
    [alert runModal];
}

- (void)quit:(NSMenuItem *)sender {
    (void)sender;
    StopEngine(&_engine);
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.metricsTimer invalidate];
    StopEngine(&_engine);
}

- (void)dealloc {
    [self.metricsTimer invalidate];
}

@end

#ifndef HEADPHONE_MONITOR_TEST
int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:delegate];
        [NSApp run];
    }
    return 0;
}
#endif
