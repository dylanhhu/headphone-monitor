#define HEADPHONE_MONITOR_TEST 1
#include "../HeadphoneMonitor.m"

#include <assert.h>
#include <stdio.h>

static AudioBufferList *CreateBufferList(UInt32 frames, UInt32 channels) {
    AudioBufferList *bufferList = calloc(1, sizeof(AudioBufferList));
    bufferList->mNumberBuffers = 1;
    bufferList->mBuffers[0].mNumberChannels = channels;
    bufferList->mBuffers[0].mDataByteSize = frames * channels * sizeof(float);
    bufferList->mBuffers[0].mData = calloc(frames * channels, sizeof(float));
    return bufferList;
}

static void DestroyBufferList(AudioBufferList *bufferList) {
    if (bufferList == NULL) {
        return;
    }
    free(bufferList->mBuffers[0].mData);
    free(bufferList);
}

int main(void) {
    @autoreleasepool {
        AudioMetrics metrics = {0};
        ResetMetrics(&metrics);

        CallbackTiming timing = {0};
        AudioTimeStamp now = {0};
        now.mFlags = kAudioTimeStampHostTimeValid;
        now.mHostTime = AudioGetCurrentHostTime();
        RecordCallback(&metrics, &timing, YES, YES, &now, 16, 96000.0, 1);

        now.mHostTime += AudioConvertNanosToHostTime(500000);
        RecordCallback(&metrics, &timing, YES, YES, &now, 16, 96000.0, 300000);
        assert(atomic_load(&metrics.inputCallbacks) == 2);
        assert(atomic_load(&metrics.outputCallbacks) == 2);
        assert(atomic_load(&metrics.deadlineMisses) == 1);
        assert(atomic_load(&metrics.cadenceMisses) == 1);
        assert(atomic_load(&metrics.maxCallbackWorkNs) == 300000);

        AudioRing ring = {0};
        ring.samples = calloc(kRingCapacityFrames, sizeof(float));
        ring.scratch = calloc(kRingCapacityFrames, sizeof(float));
        ring.metrics = &metrics;
        ring.targetFrames = 32;
        ring.outputFrames = 16;
        atomic_init(&ring.writeFrame, 0);
        atomic_init(&ring.readFrame, 0);

        AudioBufferList *output = CreateBufferList(16, 2);
        RingFillOutput(&ring, output);
        assert(atomic_load(&metrics.outputUnderrunEvents) == 1);
        assert(atomic_load(&metrics.outputUnderrunFrames) == 16);

        AudioBufferList *input = CreateBufferList(16, 1);
        float *inputSamples = input->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < 16; frame++) {
            inputSamples[frame] = 1.0f;
        }
        RingPushFirstChannel(&ring, input);
        RingFillOutput(&ring, output);
        assert(atomic_load(&metrics.outputUnderrunEvents) == 1);

        AudioBufferList *largeInput = CreateBufferList(16384, 1);
        RingPushFirstChannel(&ring, largeInput);
        AudioBufferList *overflowInput = CreateBufferList(1, 1);
        RingPushFirstChannel(&ring, overflowInput);
        assert(atomic_load(&metrics.inputDropEvents) > 0);
        assert(atomic_load(&metrics.inputDropFrames) > 0);

        AudioObjectPropertyAddress overload = {
            kAudioDeviceProcessorOverload,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        MonitorEngine engine = {0};
        engine.metrics = metrics;
        DeviceOverloadListener(0, 1, &overload, &engine);
        assert(atomic_load(&engine.metrics.deviceOverloads) == 1);

        DestroyBufferList(input);
        DestroyBufferList(largeInput);
        DestroyBufferList(overflowInput);
        DestroyBufferList(output);
        free(ring.samples);
        free(ring.scratch);
        printf("metrics tests passed\n");
    }
    return 0;
}
