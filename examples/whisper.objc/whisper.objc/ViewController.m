//
// ViewController.m — whisper.objc
//

#import "ViewController.h"
#import <whisper/whisper.h>
#import "whisper_objc-Swift.h" // Swift API access
#import "whisper.objc-Bridging-Header.h"

#define NUM_BYTES_PER_BUFFER (16 * 1024)

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UILabel    *labelStatusInp;
@property (weak, nonatomic) IBOutlet UIButton   *buttonToggleCapture;
@property (weak, nonatomic) IBOutlet UIButton   *buttonTranscribe;
@property (weak, nonatomic) IBOutlet UIButton   *buttonRealtime;
@property (weak, nonatomic) IBOutlet UITextView *textviewResult;
@end

@implementation ViewController

- (void)setupAudioFormat:(AudioStreamBasicDescription*)format
{
    format->mSampleRate       = WHISPER_SAMPLE_RATE;
    format->mFormatID         = kAudioFormatLinearPCM;
    format->mFramesPerPacket  = 1;
    format->mChannelsPerFrame = 1;
    format->mBytesPerFrame    = 2;
    format->mBytesPerPacket   = 2;
    format->mBitsPerChannel   = 16;
    format->mReserved         = 0;
    format->mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-base.en" ofType:@"bin"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        NSLog(@"Model file not found");
        return;
    }
    struct whisper_context_params params = whisper_context_default_params();
#if TARGET_OS_SIMULATOR
    params.use_gpu = false;
#endif
    stateInp.ctx = whisper_init_from_file_with_params([modelPath UTF8String], params);
    if (!stateInp.ctx) {
        NSLog(@"Failed to load model");
        return;
    }
    [self setupAudioFormat:&stateInp.dataFormat];
    stateInp.audioBufferI16 = malloc(MAX_AUDIO_SEC * SAMPLE_RATE * sizeof(int16_t));
    stateInp.audioBufferF32 = malloc(MAX_AUDIO_SEC * SAMPLE_RATE * sizeof(float));
    stateInp.n_samples = 0;
    stateInp.isCapturing = stateInp.isTranscribing = stateInp.isRealtime = NO;
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
}

#pragma mark – Transcription + Diarization

- (IBAction)onTranscribe:(id)sender {
    if (stateInp.isTranscribing) return;
    stateInp.isTranscribing = YES;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; i < self->stateInp.n_samples; i++) {
            self->stateInp.audioBufferF32[i] = self->stateInp.audioBufferI16[i] / 32768.0f;
        }

        struct whisper_full_params wfp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        wfp.print_timestamps = true;
        wfp.n_threads = MIN(8, (int)[[NSProcessInfo processInfo] processorCount]);
        wfp.single_segment = self->stateInp.isRealtime;
        wfp.no_timestamps = wfp.single_segment;

        whisper_reset_timings(self->stateInp.ctx);
        if (whisper_full(self->stateInp.ctx, wfp, self->stateInp.audioBufferF32, self->stateInp.n_samples) != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.textviewResult.text = @"Transcription failed";
                self->stateInp.isTranscribing = NO;
            });
            return;
        }

        NSURL *wavURL = [self exportRecordedPCMToWav];
        if (!wavURL) NSLog(@"❌ WAV export failed");

        DiarizerManager *diar = [DiarizerManager new];
        [diar initializeWithCompletion:^(NSError * _Nullable initErr) {
            if (initErr) {
                NSLog(@"Diarizer init error: %@", initErr);
                self->stateInp.isTranscribing = NO;
                return;
            }

            NSData *raw = [NSData dataWithBytes:self->stateInp.audioBufferF32
                                         length:self->stateInp.n_samples * sizeof(float)];
            [diar performCompleteDiarizationWithSamples:raw
                                            sampleRate:16000
                                             completion:^(NSArray<FluidDiarizerResult *> * _Nullable segs,
                                                          NSError * _Nullable diarErr) {
                if (diarErr) {
                    NSLog(@"Diarization error: %@", diarErr);
                } else {
                    NSMutableString *merged = [NSMutableString string];
                    int current = -1, total = whisper_full_n_segments(self->stateInp.ctx);
                    for (int i = 0; i < total; i++) {
                        double t0 = whisper_full_get_segment_t0(self->stateInp.ctx, i);
                        double t1 = whisper_full_get_segment_t1(self->stateInp.ctx, i);
                        const char *txt = whisper_full_get_segment_text(self->stateInp.ctx, i);
                        double mid = (t0 + t1)*0.5;
                        NSInteger sp = -1;
                        for (FluidDiarizerResult *r in segs) {
                            if (mid >= r.startTimeSeconds && mid < r.endTimeSeconds) {
                                sp = r.speakerId;
                                break;
                            }
                        }
                        if (sp != current) {
                            current = sp;
                            [merged appendFormat:@"\nSpeaker %ld:\n", (long)sp];
                        }
                        [merged appendFormat:@"%s ", txt];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.textviewResult.text = merged;
                        self->stateInp.isTranscribing = NO;
                    });
                }
            }];
        }];
    });
}

#pragma mark – WAV Export Function

#define BAIL(err,msg) if((err)!=noErr){NSLog(@"❌ %s failed: %d",msg,(int)err); if(fref)ExtAudioFileDispose(fref);return nil;}

- (NSURL*)exportRecordedPCMToWav {
    UInt32 count = stateInp.n_samples;
    if (count == 0) return nil;

    NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *url = [docs URLByAppendingPathComponent:[NSString stringWithFormat:@"rec-%@.wav",[NSUUID UUID].UUIDString]];
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = WHISPER_SAMPLE_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
    fmt.mFramesPerPacket=1; fmt.mChannelsPerFrame=1; fmt.mBitsPerChannel=16;
    fmt.mBytesPerFrame=2; fmt.mBytesPerPacket=2;

    ExtAudioFileRef fref = NULL;
    OSStatus err = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType, &fmt, NULL, kAudioFileFlags_EraseFile, &fref);
    BAIL(err,"CreateWAV");
    err = ExtAudioFileSetProperty(fref, kExtAudioFileProperty_ClientDataFormat, sizeof(fmt), &fmt); BAIL(err,"SetProp");
    AudioBufferList abl = {0};
    abl.mNumberBuffers=1;
    abl.mBuffers[0].mData = stateInp.audioBufferI16;
    abl.mBuffers[0].mDataByteSize = count*sizeof(int16_t);
    abl.mBuffers[0].mNumberChannels=1;
    err = ExtAudioFileWrite(fref, count, &abl); BAIL(err,"WriteWAV");
    ExtAudioFileDispose(fref);
    NSLog(@"✅ WAV saved to %@", url.path);
    return url;
}

@end
