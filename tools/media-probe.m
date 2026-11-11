/* Run inside the macOS guest. With --capture, exercise the drivers as well as
   enumeration, including the voice processing path used by Safari. */
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>

static void pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static BOOL authorize(AVMediaType type) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
    printf("Authorization %s: %ld\n", type.UTF8String, (long)status);
    if (status == AVAuthorizationStatusNotDetermined) {
        __block _Atomic BOOL done = NO;
        [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
            printf("Authorization %s: %s\n", type.UTF8String, granted ? "granted" : "denied");
            atomic_store(&done, YES);
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90];
        while (!atomic_load(&done) && deadline.timeIntervalSinceNow > 0) pump(0.1);
    }
    return [AVCaptureDevice authorizationStatusForMediaType:type] == AVAuthorizationStatusAuthorized;
}

@interface MediaFrames : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(atomic) unsigned frames;
@end
@implementation MediaFrames
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    CVImageBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    unsigned frame = self.frames + 1;
    self.frames = frame;
    if (frame <= 3 || frame % 15 == 0)
        printf("CAMERA_FRAME %u: %zux%zu, timestamp %.6f\n", frame, CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)));
}
@end

static BOOL captureCamera(void) {
    if (!authorize(AVMediaTypeVideo)) return NO;
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!camera) { printf("CAMERA_MISSING\n"); return NO; }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
    if (!input) { printf("CAMERA_INPUT_ERROR: %s\n", error.description.UTF8String); return NO; }
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
    MediaFrames *frames = [MediaFrames new];
    [output setSampleBufferDelegate:frames queue:dispatch_queue_create("media-probe.frames", DISPATCH_QUEUE_SERIAL)];
    [session beginConfiguration];
    [session addInput:input];
    if (![session canAddOutput:output]) { printf("CAMERA_OUTPUT_ERROR\n"); return NO; }
    [session addOutput:output];
    [session commitConfiguration];
    printf("CAMERA_START\n");
    [session startRunning];
    printf("CAMERA_RUNNING: %d\n", session.running);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (frames.frames < 30 && deadline.timeIntervalSinceNow > 0) pump(0.1);
    [session stopRunning];
    printf("CAMERA_RESULT: %u frames\n", frames.frames);
    return frames.frames >= 3;
}

static BOOL captureAudio(BOOL voiceProcessing) {
    if (!authorize(AVMediaTypeAudio)) return NO;
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioInputNode *input = engine.inputNode;
    NSError *error = nil;
    if (voiceProcessing && ![input setVoiceProcessingEnabled:YES error:&error]) {
        printf("VOICE_PROCESSING_ERROR: %s\n", error.description.UTF8String); return NO;
    }
    AVAudioFormat *format = [input outputFormatForBus:0];
    printf("AUDIO_START: voice %d, %s\n", voiceProcessing, format.description.UTF8String);
    if (!format.channelCount || format.sampleRate <= 0) { printf("AUDIO_INPUT_MISSING\n"); return NO; }
    __block _Atomic unsigned callbacks = 0, samples = 0;
    __block float peak = 0;
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        atomic_fetch_add(&callbacks, 1);
        atomic_fetch_add(&samples, buffer.frameLength);
        if (buffer.floatChannelData)
            for (unsigned i = 0; i < buffer.frameLength; i++) peak = fmaxf(peak, fabsf(buffer.floatChannelData[0][i]));
    }];
    BOOL started = [engine startAndReturnError:&error];
    printf("AUDIO_RUNNING: voice %d, %d, %s\n", voiceProcessing, started, error ? error.description.UTF8String : "OK");
    if (started) pump(5);
    [engine stop];
    [input removeTapOnBus:0];
    printf("AUDIO_RESULT: voice %d, %u callbacks, %u frames, peak %.6f\n", voiceProcessing, atomic_load(&callbacks), atomic_load(&samples), peak);
    return started && atomic_load(&callbacks) > 2 && peak > 0.001f;
}

static unsigned channels(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) || !size) return 0;
    AudioBufferList *buffers = malloc(size);
    unsigned count = 0;
    if (buffers && !AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers))
        for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) count += buffers->mBuffers[i].mNumberChannels;
    free(buffers);
    return count;
}

int main(int argc, const char *argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size)) return 1;
        AudioDeviceID *devices = malloc(size ? size : 1);
        if (!devices || AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices)) { free(devices); return 1; }
        unsigned count = size / sizeof *devices, input = 0, output = 0;
        for (unsigned i = 0; i < count; i++) {
            CFStringRef name = NULL; UInt32 length = sizeof name;
            AudioObjectPropertyAddress property = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectGetPropertyData(devices[i], &property, 0, NULL, &length, &name);
            unsigned in = channels(devices[i], kAudioObjectPropertyScopeInput);
            unsigned out = channels(devices[i], kAudioObjectPropertyScopeOutput);
            printf("%s: in %u ch, out %u ch\n", name ? [(__bridge NSString *)name UTF8String] : "Unknown", in, out);
            input += in > 0; output += out > 0;
            if (name) CFRelease(name);
        }
        free(devices);
        printf("TOTAL: %u audio devices, %u with input, %u with output\n", count, input, output);
        AudioDeviceID defaultInput = kAudioObjectUnknown;
        address.mSelector = kAudioHardwarePropertyDefaultInputDevice; size = sizeof defaultInput;
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &defaultInput);
        printf("Default audio input: %s\n", defaultInput == kAudioObjectUnknown ? "NONE" : "present");
        AVCaptureDeviceDiscoverySession *cameras = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternalUnknown, AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
        printf("Cameras visible to the guest: %lu\n", (unsigned long)cameras.devices.count);
        for (AVCaptureDevice *camera in cameras.devices) {
            printf("Camera: %s\n", camera.localizedName.UTF8String);
            for (AVCaptureDeviceFormat *format in camera.formats) {
                CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
                    printf("  %dx%d, %.2f..%.2f fps\n", dim.width, dim.height, range.minFrameRate, range.maxFrameRate);
            }
        }
        if (argc > 1 && !strcmp(argv[1], "--capture")) {
            BOOL audio = captureAudio(NO);
            BOOL voice = captureAudio(YES);
            BOOL video = captureCamera();
            printf("CAPTURE_RESULT: audio %d, voice %d, camera %d\n", audio, voice, video);
            return audio && voice && video ? 0 : 3;
        }
        return input && cameras.devices.count ? 0 : 2;
    }
}
