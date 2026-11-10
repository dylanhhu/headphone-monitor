#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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
    float *samples;
    float *scratch;
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    UInt32 targetFrames;
    UInt32 outputFrames;
    float lastSample;
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
    BOOL running;
    AudioRing ring;
} MonitorEngine;

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

    for (UInt32 frame = 0; frame < count; frame++) {
        ring->samples[(write + frame) & kRingMask] = input[frame * inputChannels];
    }
    atomic_store_explicit(&ring->writeFrame, write + count, memory_order_release);
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
        read++;
        atomic_store_explicit(&ring->readFrame, read, memory_order_release);
        available64--;
    }

    UInt32 available = available64 > UINT32_MAX ? UINT32_MAX : (UInt32)available64;
    UInt32 count = frames < available ? frames : available;
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
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;
    (void)clientData;
    CopyFirstInputChannel(inputData, outputData);
    return noErr;
}

static OSStatus InputIOProc(AudioObjectID device,
                            const AudioTimeStamp *now,
                            const AudioBufferList *inputData,
                            const AudioTimeStamp *inputTime,
                            AudioBufferList *outputData,
                            const AudioTimeStamp *outputTime,
                            void *clientData) {
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputData;
    (void)outputTime;
    RingPushFirstChannel((AudioRing *)clientData, inputData);
    return noErr;
}

static OSStatus OutputIOProc(AudioObjectID device,
                             const AudioTimeStamp *now,
                             const AudioBufferList *inputData,
                             const AudioTimeStamp *inputTime,
                             AudioBufferList *outputData,
                             const AudioTimeStamp *outputTime,
                             void *clientData) {
    (void)device;
    (void)now;
    (void)inputData;
    (void)inputTime;
    (void)outputTime;
    RingFillOutput((AudioRing *)clientData, outputData);
    return noErr;
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

    double inputRate = GetNominalSampleRate(inputDevice);
    double outputRate = GetNominalSampleRate(outputDevice);
    if (inputRate <= 0 || outputRate <= 0 || fabs(inputRate - outputRate) > 0.5) {
        return MonitorErrorSampleRateMismatch;
    }

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
    atomic_init(&engine->ring.writeFrame, 0);
    atomic_init(&engine->ring.readFrame, 0);

    status = AudioDeviceCreateIOProcID(inputDevice, InputIOProc, &engine->ring,
                                       &engine->inputProcID);
    if (status != noErr) {
        StopEngine(engine);
        return status;
    }
    status = AudioDeviceCreateIOProcID(outputDevice, OutputIOProc, &engine->ring,
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

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, assign) AudioDeviceID inputDevice;
@property(nonatomic, assign) AudioDeviceID outputDevice;
@property(nonatomic, assign) UInt32 requestedBufferFrames;
@property(nonatomic, assign) BOOL running;
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
    [self rebuildMenu];
}

- (void)stopMonitoring {
    StopEngine(&_engine);
    self.running = NO;
    [self rebuildMenu];
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
    StopEngine(&_engine);
}

@end

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
