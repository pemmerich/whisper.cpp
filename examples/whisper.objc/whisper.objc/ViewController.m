//
//  ViewController.m
//  whisper.objc
//
//  Created by Georgi Gerganov on 23.10.22.
//

#import "ViewController.h"
#import <whisper/whisper.h>
#import "whisper_objc-Swift.h"


#define NUM_BYTES_PER_BUFFER 16*1024

// callback used to process captured audio
void AudioInputCallback(void * inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp * inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription * inPacketDescs);

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

    // whisper.cpp initialization
    {
        // load the model
        NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-base.en" ofType:@"bin"];
        
        //NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-whisper-medicalv6" ofType:@"bin"];
        
        //NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-whisper-medicalv5-johnyquest7-small" ofType:@"bin"];
        
        //NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-whisper-medicalv4-saurabhy27-outcomes-large-v3" ofType:@"bin"];
        
        

        // check if the model exists
        if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
            NSLog(@"Model file not found");
            return;
        }

        NSLog(@"Loading model from %@", modelPath);

        // create ggml context

        struct whisper_context_params cparams = whisper_context_default_params();
#if TARGET_OS_SIMULATOR
        cparams.use_gpu = false;
        NSLog(@"Running on simulator, using CPU");
#endif
        stateInp.ctx = whisper_init_from_file_with_params([modelPath UTF8String], cparams);

        // check if the model was loaded successfully
        if (stateInp.ctx == NULL) {
            NSLog(@"Failed to load model");
            return;
        }
    }

    // initialize audio format and buffers
    {
        [self setupAudioFormat:&stateInp.dataFormat];

        stateInp.n_samples = 0;
        stateInp.audioBufferI16 = malloc(MAX_AUDIO_SEC*SAMPLE_RATE*sizeof(int16_t));
        stateInp.audioBufferF32 = malloc(MAX_AUDIO_SEC*SAMPLE_RATE*sizeof(float));
        // Set up audio session
        NSError *error = nil;

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:&error];
        if (error) {
            NSLog(@"Error setting audio session category: %@", error);
        }

        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            NSLog(@"Error activating audio session: %@", error);
        }

    }

    stateInp.isTranscribing = false;
    stateInp.isRealtime = false;
}

-(IBAction) stopCapturing {
    NSLog(@"Stop capturing");

    _labelStatusInp.text = @"Status: Idle";

    [_buttonToggleCapture setTitle:@"Start capturing" forState:UIControlStateNormal];
    [_buttonToggleCapture setBackgroundColor:[UIColor grayColor]];

    stateInp.isCapturing = false;

    AudioQueueStop(stateInp.queue, true);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(stateInp.queue, stateInp.buffers[i]);
    }

    AudioQueueDispose(stateInp.queue, true);
}

- (IBAction)toggleCapture:(id)sender {
    if (stateInp.isCapturing) {
        // stop capturing
        [self stopCapturing];

        return;
    }

    // initiate audio capturing
    NSLog(@"Start capturing");

    stateInp.n_samples = 0;
    stateInp.vc = (__bridge void *)(self);

    OSStatus status = AudioQueueNewInput(&stateInp.dataFormat,
                                         AudioInputCallback,
                                         &stateInp,
                                         CFRunLoopGetCurrent(),
                                         kCFRunLoopCommonModes,
                                         0,
                                         &stateInp.queue);

    if (status == 0) {
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueAllocateBuffer(stateInp.queue, NUM_BYTES_PER_BUFFER, &stateInp.buffers[i]);
            AudioQueueEnqueueBuffer (stateInp.queue, stateInp.buffers[i], 0, NULL);
        }

        stateInp.isCapturing = true;
        status = AudioQueueStart(stateInp.queue, NULL);
        if (status == 0) {
            _labelStatusInp.text = @"Status: Capturing";
            [sender setTitle:@"Stop Capturing" forState:UIControlStateNormal];
            [_buttonToggleCapture setBackgroundColor:[UIColor redColor]];
        }
    }

    if (status != 0) {
        [self stopCapturing];
    }
}

- (IBAction)onTranscribePrepare:(id)sender {
    _textviewResult.text = @"Processing - please wait ...";

    if (stateInp.isRealtime) {
        [self onRealtime:(id)sender];
    }

    if (stateInp.isCapturing) {
        [self stopCapturing];
    }
}

- (IBAction)onRealtime:(id)sender {
    stateInp.isRealtime = !stateInp.isRealtime;

    if (stateInp.isRealtime) {
        [_buttonRealtime setBackgroundColor:[UIColor greenColor]];
    } else {
        [_buttonRealtime setBackgroundColor:[UIColor grayColor]];
    }

    NSLog(@"Realtime: %@", stateInp.isRealtime ? @"ON" : @"OFF");
}

- (IBAction)onTranscribe:(id)sender {
    if (stateInp.isTranscribing) return;

    NSLog(@"Processing %d samples", stateInp.n_samples);
    stateInp.isTranscribing = true;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Convert I16 to F32
        for (int i = 0; i < self->stateInp.n_samples; i++) {
            self->stateInp.audioBufferF32[i] = (float)self->stateInp.audioBufferI16[i] / 32768.0f;
        }

        // Whisper config
        struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        const int max_threads = MIN(8, (int)[[NSProcessInfo processInfo] processorCount]);

        params.print_realtime   = true;
        params.print_progress   = false;
        params.print_timestamps = true;
        params.print_special    = false;
        params.translate        = false;
        params.language         = "en";
        params.n_threads        = max_threads;
        params.offset_ms        = 0;
        params.no_context       = true;
        params.single_segment   = self->stateInp.isRealtime;
        params.no_timestamps    = params.single_segment;

        CFTimeInterval startTime = CACurrentMediaTime();

        whisper_reset_timings(self->stateInp.ctx);
        if (whisper_full(self->stateInp.ctx, params, self->stateInp.audioBufferF32, self->stateInp.n_samples) != 0) {
            NSLog(@"Failed to run the model");
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = @"Transcription failed.";
                self->stateInp.isTranscribing = false;
            });
            return;
        }

        whisper_print_timings(self->stateInp.ctx);
        CFTimeInterval endTime = CACurrentMediaTime();

        // Convert float audio to NSArray
        NSMutableArray *samples = [NSMutableArray arrayWithCapacity:self->stateInp.n_samples];
        for (int i = 0; i < self->stateInp.n_samples; i++) {
            [samples addObject:@(self->stateInp.audioBufferF32[i])];
        }
        
        //export whisper transcript
        
        NSMutableString *whisperOutput = [NSMutableString string];
        int totalSegments = whisper_full_n_segments(self->stateInp.ctx);
        double whisperFrameDuration = 0.02; // 20ms per frame

        for (int i = 0; i < totalSegments; i++) {
            double t0 = whisper_full_get_segment_t0(self->stateInp.ctx, i) * whisperFrameDuration;
            double t1 = whisper_full_get_segment_t1(self->stateInp.ctx, i) * whisperFrameDuration;
            const char *text = whisper_full_get_segment_text(self->stateInp.ctx, i);
            [whisperOutput appendFormat:@"%.3f --> %.3f: %s\n", t0, t1, text];
        }

        // Save to file
        NSError *whisperErr = nil;
        NSString *whisperFilename = [NSString stringWithFormat:@"whisper-raw-%@.txt", [NSUUID UUID].UUIDString];
        NSURL *whisperURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject URLByAppendingPathComponent:whisperFilename];
        BOOL whisperSaved = [whisperOutput writeToURL:whisperURL atomically:YES encoding:NSUTF8StringEncoding error:&whisperErr];
        if (whisperSaved) {
            NSLog(@"✅ Whisper raw transcript exported: %@", whisperURL.path);
        } else {
            NSLog(@"❌ Whisper export failed: %@", whisperErr);
        }

        
        NSLog(@"📦 Sending %lu samples to DiarizerBridge...", (unsigned long)[samples count]);
        
        // Call Swift diarization bridge
        [DiarizerBridge diarizeWithSamples:samples
                                sampleRate:16000
                                completion:^(NSArray *segments, NSError *error) {
            if (error) {
                NSLog(@"❌ Diarization failed: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_textviewResult.text = @"Diarization failed.";
                    self->stateInp.isTranscribing = false;
                });
                return;
            }
            NSLog(@"📊 Raw diarization segments:\n%@", segments);
            
            //export raw diarization to file
            
            NSMutableString *diarizationOutput = [NSMutableString string];
            for (NSDictionary *seg in segments) {
                double start = [seg[@"startTime"] doubleValue];
                double end = [seg[@"endTime"] doubleValue];
                NSString *speaker = seg[@"speakerId"];
                [diarizationOutput appendFormat:@"%@: %.3f --> %.3f\n", speaker, start, end];
            }

            // Save to file
            NSError *diarErr = nil;
            NSString *diarFilename = [NSString stringWithFormat:@"diarization-raw-%@.txt", [NSUUID UUID].UUIDString];
            NSURL *diarURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject URLByAppendingPathComponent:diarFilename];
            BOOL diarSaved = [diarizationOutput writeToURL:diarURL atomically:YES encoding:NSUTF8StringEncoding error:&diarErr];
            if (diarSaved) {
                NSLog(@"✅ Diarization segments exported: %@", diarURL.path);
            } else {
                NSLog(@"❌ Diarization export failed: %@", diarErr);
            }

            
            // 🎙 Merge transcript with speaker labels
            NSMutableString *output = [NSMutableString string];
            int totalSegments = whisper_full_n_segments(self->stateInp.ctx);
            NSInteger lastSpeaker = -1;
            
            double timeOffset = 0.0;
            if (segments.count > 0) {
                NSDictionary *firstSeg = segments[0];
                timeOffset = [firstSeg[@"startTime"] doubleValue] - 0.5; // buffer
            }
            
            NSLog(@"⏱️ Applying timeOffset: %.2f", timeOffset);

            
            for (int i = 0; i < totalSegments; i++) {
                double t0 = whisper_full_get_segment_t0(self->stateInp.ctx, i);
                double t1 = whisper_full_get_segment_t1(self->stateInp.ctx, i);
                const char *text = whisper_full_get_segment_text(self->stateInp.ctx, i);
                double whisperFrameDuration = 0.02; // 20ms per frame
                //double mid = ((t0 + t1) * 0.5 * whisperFrameDuration) + timeOffset;
                double t0_sec = t0 * whisperFrameDuration;
                double t1_sec = t1 * whisperFrameDuration;
                
                
                /*
                //using mid logic
                 
                double mid = (t0_sec + t1_sec) / 2.0 + timeOffset;
                NSLog(@"🔍 Segment %d: t0 = %.2f, t1 = %.2f, mid = %.2f",
                      i, t0_sec, t1_sec, mid);



                NSInteger speakerId = -1;
                double bestDistance = DBL_MAX;

                // 🔍 Find matching diarization segment
                // Fallback to closest diarization segment if no match
                for (NSDictionary *seg in segments) {
                   
                    
                    double start = [seg[@"startTime"] doubleValue];
                    double end = [seg[@"endTime"] doubleValue];

                    // Try to extract speaker number from string like "Speaker 1"
                    NSString *speakerStr = seg[@"speakerId"];
                    NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                    [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                    NSInteger candidateSpeaker = -1;
                    [scanner scanInteger:&candidateSpeaker];
                    
                    NSLog(@"🧭 Diarizer seg: start = %.2f, end = %.2f, speaker = %@",
                          start, end, speakerStr);
                    
                    // Check if mid falls inside this segment
                    if (mid >= start && mid < end) {
                        speakerId = candidateSpeaker;
                        NSLog(@"🎤Mid Match! Segment %d: %.2f–%.2f → speaker %ld", i, t0, t1, (long)speakerId);
                        break;
                    }

                    // Or: track closest segment by midpoint distance
                    //double segMid = (start + end) / 2.0;
                    double segMid = (start + end) / 2.0;
                    double distance = fabs(mid - segMid);
                    if (distance < bestDistance) {
                        bestDistance = distance;
                        speakerId = candidateSpeaker;
                    }
                }
                
                if (speakerId == -1) {
                    NSLog(@"🚨 No diarization match for mid %.2f – using fallback speaker %ld", mid, (long)speakerId);
                }
                */
                
                //using overlap logic
                
                double startSec = t0 * whisperFrameDuration + timeOffset;
                double endSec = t1 * whisperFrameDuration + timeOffset;

                NSInteger speakerId = -1;
                NSTimeInterval maxOverlap = 0;

                for (NSDictionary *seg in segments) {
                    double segStart = [seg[@"startTime"] doubleValue];
                    double segEnd = [seg[@"endTime"] doubleValue];

                    NSString *speakerStr = seg[@"speakerId"];
                    NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                    [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                    NSInteger candidateSpeaker = -1;
                    [scanner scanInteger:&candidateSpeaker];

                    // Overlap calculation
                    double overlapStart = MAX(startSec, segStart);
                    double overlapEnd = MIN(endSec, segEnd);
                    double overlap = overlapEnd - overlapStart;
                    
                    if (overlap > 0) {
                        NSLog(@"🔄 Overlap with %@: transcript[%.2f–%.2f] vs diarizer[%.2f–%.2f] → %.2f seconds",
                                  speakerStr, startSec, endSec, segStart, segEnd, overlap);
                    }


                    if (overlap > maxOverlap) {
                        maxOverlap = overlap;
                        speakerId = candidateSpeaker;
                    }
                }

                if (speakerId == -1) {
                    NSLog(@"🚨 No overlap match for segment %.2f–%.2f", startSec, endSec);
                } else {
                    NSLog(@"🎤 Segment %d: %.2f–%.2f → speaker %ld", i, startSec, endSec, (long)speakerId);
                }

                
                // 🏷 If speaker changed or wasn't yet set, print label
                if (i == 0 || speakerId != lastSpeaker) {
                    [output appendFormat:@"\nSpeaker %ld:\n", (long)speakerId];
                    lastSpeaker = speakerId;
                }

                [output appendFormat:@"%s ", text];
            }
            
                
            // 📁 Export the result to a .txt file
            NSError *writeErr = nil;
            NSString *filename = [NSString stringWithFormat:@"transcript-diarized-%@.txt", [NSUUID UUID].UUIDString];
            NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *fileURL = [docs URLByAppendingPathComponent:filename];
            BOOL success = [output writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = output;

                if (success) {
                    NSLog(@"✅ Transcript exported: %@", fileURL.path);
                } else {
                    NSLog(@"❌ Failed to export transcript: %@", writeErr);
                }

                self->stateInp.isTranscribing = false;
            });
        }];



    });
}

//
// Callback implementation
//

void AudioInputCallback(void * inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp * inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription * inPacketDescs)
{
    StateInp * stateInp = (StateInp*)inUserData;

    if (!stateInp->isCapturing) {
        NSLog(@"Not capturing, ignoring audio");
        return;
    }

    const int n = inBuffer->mAudioDataByteSize / 2;

    NSLog(@"Captured %d new samples", n);

    if (stateInp->n_samples + n > MAX_AUDIO_SEC*SAMPLE_RATE) {
        NSLog(@"Too much audio data, ignoring");

        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController * vc = (__bridge ViewController *)(stateInp->vc);
            [vc stopCapturing];
        });

        return;
    }

    for (int i = 0; i < n; i++) {
        stateInp->audioBufferI16[stateInp->n_samples + i] = ((short*)inBuffer->mAudioData)[i];
    }

    stateInp->n_samples += n;

    // put the buffer back in the queue
    AudioQueueEnqueueBuffer(stateInp->queue, inBuffer, 0, NULL);

    if (stateInp->isRealtime) {
        // dipatch onTranscribe() to the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController * vc = (__bridge ViewController *)(stateInp->vc);
            [vc onTranscribe:nil];
        });
    }
}

// Add at the top of the file, below imports
#define BAIL_ON_ERR(err, msg) \
  if ((err) != noErr) { \
    NSLog(@"❌ %s failed: %d", msg, (int)(err)); \
    if (fref) ExtAudioFileDispose(fref); \
    return nil; \
  }

- (NSURL*)exportRecordedPCMToWav {
    UInt32 count = stateInp.n_samples;
    NSLog(@"🎙 exportRecordedPCMToWav: sampleCount = %u", count);
    if (count < WHISPER_SAMPLE_RATE / 4) { // warn if less than 500 ms
        NSLog(@"⚠️ Too few samples for valid WAV.");
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *docs = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSString *fn = [NSString stringWithFormat:@"rec-%@.wav", [NSUUID UUID].UUIDString];
    NSURL *url = [docs URLByAppendingPathComponent:fn];
    NSURL *outerr = url;
    // Audio Format (must include IsPacked to avoid 'fmt?' error)
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate       = WHISPER_SAMPLE_RATE;           // 16 000.0
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger
                          | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket  = 1;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel   = 16;
    fmt.mBytesPerFrame    = (fmt.mBitsPerChannel/8) * fmt.mChannelsPerFrame;
    fmt.mBytesPerPacket   = fmt.mBytesPerFrame;
    fmt.mReserved         = 0;

    ExtAudioFileRef fref = NULL;
    OSStatus err = ExtAudioFileCreateWithURL((__bridge CFURLRef)url,
                                              kAudioFileWAVEType,
                                              &fmt,
                                              NULL,
                                              kAudioFileFlags_EraseFile,
                                              &fref);
    BAIL_ON_ERR(err, "ExtAudioFileCreateWithURL");

    err = ExtAudioFileSetProperty(fref,
                                  kExtAudioFileProperty_ClientDataFormat,
                                  sizeof(fmt),
                                  &fmt);
    BAIL_ON_ERR(err, "ExtAudioFileSetProperty");

    AudioBufferList abl = {0};
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mData = stateInp.audioBufferI16;
    abl.mBuffers[0].mDataByteSize = count * sizeof(int16_t);
    abl.mBuffers[0].mNumberChannels = 1;

    err = ExtAudioFileWrite(fref, count, &abl);
    BAIL_ON_ERR(err, "ExtAudioFileWrite");

    ExtAudioFileDispose(fref);
    NSLog(@"✅ WAV saved to %@", url.path);
    return outerr;
}



@end
