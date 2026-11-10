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

        AudioValueRange bufferRange = { .mMinimum = 14.0, .mMaximum = 4096.0 };
        assert(ResolveBufferFrameSize(kRequestedMinimumBufferFrames, bufferRange) == 14);
        assert(ResolveBufferFrameSize(1, bufferRange) == 14);
        assert(ResolveBufferFrameSize(32, bufferRange) == 32);
        assert(ResolveBufferFrameSize(8192, bufferRange) == 4096);
        assert(BridgePrefillFrames(16, 32) == 48);
        assert(BridgePrefillFrames(32, 32) == 64);
        assert(BridgePrefillFrames(512, 32) == 544);

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
        float *outputSamples = output->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < 16; frame++) {
            assert(outputSamples[frame * 2] == 1.0f);
            assert(outputSamples[frame * 2 + 1] == 1.0f);
        }

        AudioBufferList *largeInput = CreateBufferList(16384, 1);
        RingPushFirstChannel(&ring, largeInput);
        AudioBufferList *overflowInput = CreateBufferList(1, 1);
        RingPushFirstChannel(&ring, overflowInput);
        assert(atomic_load(&metrics.inputDropEvents) > 0);
        assert(atomic_load(&metrics.inputDropFrames) > 0);

        ResetMetrics(&metrics);
        atomic_store(&ring.writeFrame, 0);
        atomic_store(&ring.readFrame, 0);
        ring.lastSample = 0;
        atomic_store(&ring.trimOnFirstRead, 1);
        AudioBufferList *trimInput = CreateBufferList(64, 1);
        float *trimSamples = trimInput->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < 64; frame++) {
            trimSamples[frame] = (float)frame;
        }
        RingPushFirstChannel(&ring, trimInput);
        RingFillOutput(&ring, output);
        assert(atomic_load(&metrics.startupTrimFrames) == 32);
        assert(outputSamples[0] == 32.0f);
        assert(outputSamples[31] == 47.0f);

        ResetMetrics(&metrics);
        uint64_t wrapStart = kRingCapacityFrames - 8;
        atomic_store(&ring.writeFrame, wrapStart);
        atomic_store(&ring.readFrame, wrapStart);
        AudioBufferList *wrapInput = CreateBufferList(16, 1);
        float *wrapSamples = wrapInput->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < 16; frame++) {
            wrapSamples[frame] = (float)(100 + frame);
        }
        RingPushFirstChannel(&ring, wrapInput);
        RingFillOutput(&ring, output);
        assert(outputSamples[0] == 100.0f);
        assert(outputSamples[14] == 107.0f);
        assert(outputSamples[16] == 108.0f);
        assert(outputSamples[30] == 115.0f);

        ResetMetrics(&metrics);
        ring.inputFrames = 512;
        ring.targetFrames = 544;
        ring.outputFrames = 32;
        atomic_store(&ring.writeFrame, 1024);
        atomic_store(&ring.readFrame, 0);
        RingFillOutput(&ring, output);
        assert(atomic_load(&metrics.driftCorrectionEvents) == 0);

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
        DestroyBufferList(trimInput);
        DestroyBufferList(wrapInput);
        DestroyBufferList(output);
        free(ring.samples);
        printf("metrics tests passed\n");
    }
    return 0;
}
