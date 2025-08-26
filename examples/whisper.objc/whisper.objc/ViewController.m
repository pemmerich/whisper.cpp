//
//  ViewController.m
//  whisper.objc
//
//  Created by Georgi Gerganov on 23.10.22.
//

#import "ViewController.h"
#import <whisper/whisper.h>
#import "whisper_objc-Swift.h"
#import "WhisperOutputRedirector.h"


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
@property (weak, nonatomic) IBOutlet UIButton   *buttonTestTranscribe;
@property (weak, nonatomic) IBOutlet UIButton   *buttonCleanSummarize;
@property (weak, nonatomic) IBOutlet UIButton   *buttonSendToOpenAI;
@property (weak, nonatomic) IBOutlet UIButton   *buttonRealtime;
@property (weak, nonatomic) IBOutlet UITextView *textviewResult;
@property (weak, nonatomic) IBOutlet UITextView *textviewPrompt;

// model dropdown
@property (weak, nonatomic) IBOutlet UIButton *buttonModel;
@property (nonatomic, copy) NSString *selectedModel;
@property (nonatomic, strong) NSArray<NSString *> *availableModels;


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
    
    [_buttonTranscribe setHidden:YES];
    [_buttonTestTranscribe setHidden:NO];
    [_buttonCleanSummarize setHidden:YES];
    [_buttonSendToOpenAI setHidden:YES];
    [_textviewPrompt setHidden:YES];
    
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
        
        // List whatever models you want to expose
        self.availableModels = @[
            // GPT-4.x family
            @"gpt-4o",           // Multimodal “Omni” model :contentReference[oaicite:1]{index=1}
            @"gpt-4o-mini",      // Smaller/faster gpt-4o variant :contentReference[oaicite:2]{index=2}

            // GPT-4.1 coding-focused models
            @"gpt-4.1",          // Released April 2025 for coding :contentReference[oaicite:3]{index=3}
            @"gpt-4.1-mini",     // Smaller and cheaper variant :contentReference[oaicite:4]{index=4}

            // GPT-4.5 (Orion)—now deprecated
            @"gpt-4.5",          // February 2025 release, retired August 2025 :contentReference[oaicite:5]{index=5}

            // "o" reasoning series
            @"o1",               // Enhanced reasoning model :contentReference[oaicite:6]{index=6}
            @"o1-mini",          // Cheaper, faster version :contentReference[oaicite:7]{index=7}
            @"o1-pro",           // High-compute variant :contentReference[oaicite:8]{index=8}
            @"o3",               // Successor reasoning model :contentReference[oaicite:9]{index=9}
            @"o3-mini",          // Compact o3 variant :contentReference[oaicite:10]{index=10}
            @"o3-mini-high",     // Higher-effort reasoning in o3-mini :contentReference[oaicite:11]{index=11}

            // GPT-5 family
            @"gpt-5",                // Flagship multimodal model (Aug 7, 2025) :contentReference[oaicite:12]{index=12}
            @"gpt-5-mini",           // Smaller/generally faster variant :contentReference[oaicite:13]{index=13}
            @"gpt-5-nano",           // Even more streamlined version :contentReference[oaicite:14]{index=14}
            @"gpt-5-thinking",       // Deeper reasoning specialization :contentReference[oaicite:15]{index=15}
            @"gpt-5-thinking-mini",  // Smaller reasoning variant :contentReference[oaicite:16]{index=16}
            @"gpt-5-thinking-nano",  // Compact reasoning variant :contentReference[oaicite:17]{index=17}

            // Legacy fallback
            @"gpt-3.5-turbo"         // Widely-used classic fallback
        ];


        // Load last selection or default
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedModel"];
        self.selectedModel = saved ?: @"gpt-5";
        [self.buttonModel setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                              forState:UIControlStateNormal];

        [self configureModelMenu];
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
    
    [_buttonTranscribe setHidden:NO];
    [_buttonTestTranscribe setHidden:YES];
    
   

    stateInp.isCapturing = false;

    AudioQueueStop(stateInp.queue, true);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        if (stateInp.buffers[i]) {
            AudioQueueFreeBuffer(stateInp.queue, stateInp.buffers[i]);
            stateInp.buffers[i] = NULL;
        }
    }
    AudioQueueDispose(stateInp.queue, true);
    stateInp.queue = NULL;
}

- (IBAction)toggleCapture:(id)sender {
    if (stateInp.isCapturing) {
        // stop capturing
        [self stopCapturing];

        return;
    }

    // initiate audio capturing
    NSLog(@"Start capturing");
    
    [_buttonTestTranscribe setHidden:YES];
    [_buttonTranscribe setHidden:YES];
    [_buttonCleanSummarize setHidden:YES];
    
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
    _labelStatusInp.text = @"Status: Processing";
    
    
    
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
    
    [_buttonCleanSummarize setHidden:YES];
    [_buttonSendToOpenAI setHidden:YES];
    [_buttonTranscribe setHidden:YES];
    [_buttonTestTranscribe setHidden:YES];
    [_buttonToggleCapture setHidden:YES];
    
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
        //params.single_segment   = self->stateInp.isRealtime;
        //params.no_timestamps    = params.single_segment;
        params.single_segment   = false;
        params.no_timestamps    = false;
    

        CFTimeInterval startTime = CACurrentMediaTime();
        
        /*
        NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"whisper-transcript.txt"];
        [WhisperOutputRedirector redirectStdoutToFileAtPath:outputPath];
         */
        NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"whisper-transcript-%@.txt", [NSUUID UUID].UUIDString]];
        [WhisperOutputRedirector redirectStdoutToFileAtPath:outputPath];
        
        whisper_reset_timings(self->stateInp.ctx);
        if (whisper_full(self->stateInp.ctx, params, self->stateInp.audioBufferF32, self->stateInp.n_samples) != 0) {
            NSLog(@"Failed to run the model");
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = @"Transcription failed.";
                self->stateInp.isTranscribing = false;
            });
            [self finishTranscribeResetUI];
            [WhisperOutputRedirector restoreStdout];
            return;
        }
        
        [WhisperOutputRedirector restoreStdout];

        NSLog(@"✅ Whisper Print Out transcript saved to %@", outputPath);
        NSError *readError = nil;
        NSString *printedTranscript = [NSString stringWithContentsOfFile:outputPath encoding:NSUTF8StringEncoding error:&readError];
        if (readError) {
            NSLog(@"❌ Failed to read whisper transcript: %@", readError);
        } else {
            NSLog(@"📄 Loaded printed transcript, length = %lu", (unsigned long)printedTranscript.length);
        }
        
        
        whisper_print_timings(self->stateInp.ctx);
        CFTimeInterval endTime = CACurrentMediaTime();

        // Convert float audio to NSArray
        NSMutableArray *samples = [NSMutableArray arrayWithCapacity:self->stateInp.n_samples];
        for (int i = 0; i < self->stateInp.n_samples; i++) {
            [samples addObject:@(self->stateInp.audioBufferF32[i])];
        }
        
        //export wav file
        NSURL *wavURL = [self exportRecordedPCMToWav];
        if (wavURL) {
            NSLog(@"✅ Exported WAV: %@", wavURL.path);
        } else {
            NSLog(@"❌ exportRecordedPCMToWav returned nil");
        }
        
        //export whisper transcript
        
        NSMutableString *whisperOutput = [NSMutableString string];
        int totalSegments = whisper_full_n_segments(self->stateInp.ctx);
        double whisperFrameDuration = 0.016; // 16ms per frame

        for (int i = 0; i < totalSegments; i++) {
            
            double t0 = whisper_full_get_segment_t0(self->stateInp.ctx, i);
            double t1 = whisper_full_get_segment_t1(self->stateInp.ctx, i);
            const char *text = whisper_full_get_segment_text(self->stateInp.ctx, i);
            NSLog(@"Raw Segment %i Raw frame t0 = %f, t1 = %f",i, t0, t1);
            
            double t0_sec = t0 * whisperFrameDuration;
            double t1_sec = t1 * whisperFrameDuration;
            
            //make sure we're gettign valid timestamp frames
            if (t0_sec < 0 || t1_sec < 0 || t1_sec < t0_sec) {
                    NSLog(@"🚨 Invalid segment timing: t0 = %d, t1 = %d", t0_sec, t1_sec);
                    continue;
                }
            
            //[whisperOutput appendFormat:@"%.3f --> %.3f: %s\n", t0, t1, text];
            [whisperOutput appendFormat:@"[%02d:%02d:%06.3f --> %02d:%02d:%06.3f]   %s\n",
                    (int)(t0_sec / 3600), ((int)(t0_sec) % 3600) / 60, fmod(t0, 60),
                    (int)(t1_sec / 3600), ((int)(t1_sec) % 3600) / 60, fmod(t1, 60),
                    text];
            
            double durationSec = (double)stateInp.n_samples / 16000.0;
            NSLog(@"🔍 Total audio duration = %.2f sec", durationSec);
            
            
            NSLog(@"Computed seconds t0 = %.3f, t1 = %.3f", t0_sec, t1_sec);

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
                [self finishTranscribeResetUI];
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

            
            // new merge logic using whisper print output
            NSArray *transcriptEntries = [self parsePrintedTranscript:printedTranscript];
            NSMutableString *mergedOutput = [NSMutableString string];
            NSInteger lastSpeaker = -1;
            
            NSDate *now = [NSDate date];
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss zzzz";
            NSString *sessionHeader = [NSString stringWithFormat:@"Recorded at: %@\n", [df stringFromDate:now]];
            [mergedOutput appendString:sessionHeader];

            
            /*
            for (NSDictionary *entry in transcriptEntries) {
                double t0 = [entry[@"start"] doubleValue];
                double t1 = [entry[@"end"] doubleValue];
                NSString *text = entry[@"text"];
                
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

                    // Calculate overlap
                    double overlapStart = MAX(t0, segStart);
                    double overlapEnd = MIN(t1, segEnd);
                    double overlap = overlapEnd - overlapStart;
                    
                    if (overlap > maxOverlap) {
                        maxOverlap = overlap;
                        speakerId = candidateSpeaker;
                    }
                }

                if (speakerId != lastSpeaker) {
                    [mergedOutput appendFormat:@"\nSpeaker %ld:\n", (long)speakerId];
                    lastSpeaker = speakerId;
                }

                [mergedOutput appendFormat:@"%@\n", text];
            }
             */
            
            /*
            //hybrid midpoint logic falling back to overlap
            for (NSDictionary *entry in transcriptEntries) {
                double t0 = [entry[@"start"] doubleValue];
                double t1 = [entry[@"end"] doubleValue];
                NSString *text = entry[@"text"];
                
                double mid = (t0 + t1) / 2.0;
                NSInteger speakerId = -1;
                BOOL midMatched = NO;
                
                // First try: Midpoint matching
                for (NSDictionary *seg in segments) {
                    double segStart = [seg[@"startTime"] doubleValue];
                    double segEnd = [seg[@"endTime"] doubleValue];
                    
                    if (mid >= segStart && mid < segEnd) {
                        NSString *speakerStr = seg[@"speakerId"];
                        NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                        [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                        [scanner scanInteger:&speakerId];
                        
                        midMatched = YES;
                        break;
                    }
                }
                
                // Fallback: Overlap logic
                if (!midMatched) {
                    NSTimeInterval maxOverlap = 0;
                    for (NSDictionary *seg in segments) {
                        double segStart = [seg[@"startTime"] doubleValue];
                        double segEnd = [seg[@"endTime"] doubleValue];

                        double overlapStart = MAX(t0, segStart);
                        double overlapEnd = MIN(t1, segEnd);
                        double overlap = overlapEnd - overlapStart;

                        if (overlap > maxOverlap) {
                            maxOverlap = overlap;

                            NSString *speakerStr = seg[@"speakerId"];
                            NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                            [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                            [scanner scanInteger:&speakerId];
                        }
                    }
                }

                if (speakerId != lastSpeaker) {
                    [mergedOutput appendFormat:@"\nSpeaker %ld:\n", (long)speakerId];
                    lastSpeaker = speakerId;
                }

                [mergedOutput appendFormat:@"%@\n", text];
            }
             */
            
            //new hybrid approach the accounts for low overlap fallback
            /*
            for (NSDictionary *entry in transcriptEntries) {
                double t0 = [entry[@"start"] doubleValue];
                double t1 = [entry[@"end"] doubleValue];
                NSString *text = entry[@"text"];
                
                NSInteger speakerId = -1;
                double mid = (t0 + t1) / 2.0;

                // --- Try midpoint match ---
                for (NSDictionary *seg in segments) {
                    double segStart = [seg[@"startTime"] doubleValue];
                    double segEnd = [seg[@"endTime"] doubleValue];
                    
                    if (mid >= segStart && mid <= segEnd) {
                        NSString *speakerStr = seg[@"speakerId"];
                        NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                        [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                        [scanner scanInteger:&speakerId];
                        
                        NSLog(@"🎯 Midpoint match: %.3f inside [%.3f – %.3f] → Speaker %ld",
                              mid, segStart, segEnd, (long)speakerId);
                        break;
                    }
                }

                // --- If midpoint failed, try overlap fallback ---
                if (speakerId == -1) {
                    double maxOverlap = 0;
                    for (NSDictionary *seg in segments) {
                        double segStart = [seg[@"startTime"] doubleValue];
                        double segEnd = [seg[@"endTime"] doubleValue];

                        double overlapStart = MAX(t0, segStart);
                        double overlapEnd = MIN(t1, segEnd);
                        double overlap = overlapEnd - overlapStart;

                        if (overlap > maxOverlap) {
                            maxOverlap = overlap;

                            NSString *speakerStr = seg[@"speakerId"];
                            NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                            [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                            [scanner scanInteger:&speakerId];
                        }
                    }
                    
                    if (speakerId != -1) {
                        NSLog(@"📦 Fallback overlap match: max overlap %.3f → Speaker %ld",
                              maxOverlap, (long)speakerId);
                    }
                }


                if (speakerId != lastSpeaker) {
                    [mergedOutput appendFormat:@"\nSpeaker %ld:\n", (long)speakerId];
                    lastSpeaker = speakerId;
                }

                [mergedOutput appendFormat:@"%@\n", text];
            }
            */
            
            // new hybrid approach with mid point buffers falling back to max overlap
            for (NSDictionary *entry in transcriptEntries) {
                double t0 = [entry[@"start"] doubleValue];
                double t1 = [entry[@"end"] doubleValue];
                NSString *text = entry[@"text"];
                
                NSInteger speakerId = -1;
                double buffer = 0.3; // seconds to shrink from edges
                double t0_adj = MAX(0.0, t0 + buffer);
                double t1_adj = MAX(t0_adj, t1 - buffer); // ensure t1_adj >= t0_adj
                double mid = (t0_adj + t1_adj) / 2.0;

                BOOL usedMidpoint = NO;

                // --- Try midpoint match with buffer ---
                for (NSDictionary *seg in segments) {
                    double segStart = [seg[@"startTime"] doubleValue];
                    double segEnd = [seg[@"endTime"] doubleValue];
                    
                    if (mid >= segStart && mid <= segEnd) {
                        NSString *speakerStr = seg[@"speakerId"];
                        NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                        [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                        [scanner scanInteger:&speakerId];
                        
                        NSLog(@"🎯 Midpoint match: mid %.3f in [%.3f – %.3f] → Speaker %ld",
                              mid, segStart, segEnd, (long)speakerId);
                        usedMidpoint = YES;
                        break;
                    }
                }

                // --- If midpoint failed, try overlap fallback ---
                if (!usedMidpoint) {
                    double maxOverlap = 0;
                    for (NSDictionary *seg in segments) {
                        double segStart = [seg[@"startTime"] doubleValue];
                        double segEnd = [seg[@"endTime"] doubleValue];

                        double overlapStart = MAX(t0, segStart);
                        double overlapEnd = MIN(t1, segEnd);
                        double overlap = overlapEnd - overlapStart;

                        if (overlap > maxOverlap) {
                            maxOverlap = overlap;

                            NSString *speakerStr = seg[@"speakerId"];
                            NSScanner *scanner = [NSScanner scannerWithString:speakerStr];
                            [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                            [scanner scanInteger:&speakerId];
                        }
                    }
                    
                    if (speakerId != -1) {
                        NSLog(@"📦 Fallback overlap match: max overlap %.3f → Speaker %ld",
                              maxOverlap, (long)speakerId);
                    } else {
                        NSLog(@"🚨 No match found for segment: %.3f–%.3f", t0, t1);
                    }
                }

                // --- Speaker tag and text output ---
                if (speakerId != lastSpeaker) {
                    NSString *ts = [self hmsFromSeconds:t0]; // t0 is the entry start (seconds)
                    [mergedOutput appendFormat:@"\n[%@] Speaker %ld:\n", ts, (long)speakerId];
                    lastSpeaker = speakerId;
                }

                NSString *lineTs = [self hmsFromSeconds:t0];
                [mergedOutput appendFormat:@"[%@] %@\n", lineTs, text];
            }

            
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = [NSString stringWithFormat:@"Rough Draft Transcript:\n\n%@", mergedOutput];
                [self finishTranscribeResetUI];
                _labelStatusInp.text = @"Status: Rough Draft";
                [_buttonCleanSummarize setHidden:NO];
                [_buttonTranscribe setHidden:YES];
                [_buttonToggleCapture setHidden:NO];
                
                NSDateFormatter *fnDf = [[NSDateFormatter alloc] init];
                fnDf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                fnDf.dateFormat = @"yyyyMMdd-HHmmss";
                NSString *stamp = [fnDf stringFromDate:[NSDate date]];
                NSString *mergedFilename = [NSString stringWithFormat:@"merged-transcript-%@.txt", stamp];
                
                //NSString *mergedFilename = [NSString stringWithFormat:@"merged-transcript-%@.txt", [NSUUID UUID].UUIDString];
                NSURL *mergedURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject URLByAppendingPathComponent:mergedFilename];
                
                NSError *writeErr = nil;
                [mergedOutput writeToURL:mergedURL atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
                
                if (!writeErr) {
                    NSLog(@"✅ Merged diarized transcript saved to %@", mergedURL.path);
                } else {
                    NSLog(@"❌ Failed to save merged transcript: %@", writeErr);
                }
            });
            
            
        }];



    });
}


- (IBAction)testSummarizeTranscript:(id)sender {
    NSURL *latestURL = [self latestDiarizedTranscriptURL];
    if (!latestURL) {
        NSLog(@"❌ No diarized transcript found.");
        return;
    }

    NSError *readErr = nil;
    NSString *rawTranscript = [NSString stringWithContentsOfURL:latestURL encoding:NSUTF8StringEncoding error:&readErr];
    if (readErr || !rawTranscript.length) {
        NSLog(@"❌ Failed to read latest transcript: %@", readErr);
        return;
    }

    NSLog(@"📄 Loaded transcript from: %@", latestURL.path);
    
    _textviewResult.text = [NSString stringWithFormat:@"Rough Draft Transcript:\n\n%@", rawTranscript];;
    

    // summarize and clean
    //[self summarizeAndCleanTranscript:rawTranscript];
    [_buttonCleanSummarize setHidden:NO];
}

- (IBAction)cleanSummarizeTranscript:(id)sender {
    NSURL *latestURL = [self latestDiarizedTranscriptURL];
    if (!latestURL) {
        NSLog(@"❌ No diarized transcript found.");
        return;
    }

    NSError *readErr = nil;
    NSString *rawTranscript = [NSString stringWithContentsOfURL:latestURL encoding:NSUTF8StringEncoding error:&readErr];
    if (readErr || !rawTranscript.length) {
        NSLog(@"❌ Failed to read latest transcript: %@", readErr);
        return;
    }
        
    [_buttonTestTranscribe setHidden:YES];
    [_buttonTranscribe setHidden:YES];
    [_buttonCleanSummarize setHidden:YES];
    [_buttonToggleCapture setHidden:YES];
    
    // summarize and clean
    [self summarizeAndCleanTranscript:rawTranscript];
}

- (void) summarizeAndCleanTranscript:(NSString *)rawTranscript
{
    [_textviewResult setContentOffset:CGPointZero animated:YES];
    _labelStatusInp.text = @"Status: Cleaning";
    _textviewResult.text = [NSString stringWithFormat:@"Cleaning up the transcript...\n\nRough Draft:\n%@", rawTranscript];
    NSString *prompt = [NSString stringWithFormat:
        @"Below is a diarized transcript of a conversation with timestamps. Keep the timestamps and do the following:\n\n"
        "1. Check for medical term accuracy and where you feel confident, change the transcript to what you think the speaker meant to say. Don't change grammar or sentence\n"
        "2. Clean up the speaker diarization.\n"
        "3. At the end, provide a concise summary of the key points discussed.\n\n\n%@",
        rawTranscript];

    // 🔥 Send prompt to OpenAI
    //[self callOpenAIWithPrompt:prompt];
    //[self callOpenAIResponsesWithPrompt:prompt];
    
    // Show editable prompt
        self.textviewPrompt.text = prompt;
    [_textviewPrompt setHidden:NO];
        self.textviewResult.text = @"✏️ Please review and edit the prompt below, then press 'Send to OpenAI'.";
        
        // Reveal a "Send" button
        [_buttonSendToOpenAI setHidden:NO];
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

- (NSArray<NSDictionary *> *)parsePrintedTranscript:(NSString *)transcript {
    NSMutableArray *results = [NSMutableArray array];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{2}):(\\d{2}):(\\d{2}\\.\\d{3}) --> (\\d{2}):(\\d{2}):(\\d{2}\\.\\d{3})\\]\\s+(.*)"
                                                                           options:0
                                                                             error:nil];
    
    NSArray *lines = [transcript componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (match.numberOfRanges == 8) {
            double t0 = [line substringWithRange:[match rangeAtIndex:1]].doubleValue * 3600 +
                        [line substringWithRange:[match rangeAtIndex:2]].doubleValue * 60 +
                        [line substringWithRange:[match rangeAtIndex:3]].doubleValue;
            double t1 = [line substringWithRange:[match rangeAtIndex:4]].doubleValue * 3600 +
                        [line substringWithRange:[match rangeAtIndex:5]].doubleValue * 60 +
                        [line substringWithRange:[match rangeAtIndex:6]].doubleValue;
            NSString *text = [line substringWithRange:[match rangeAtIndex:7]];

            [results addObject:@{ @"start": @(t0), @"end": @(t1), @"text": text }];
        }
    }
    return results;
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

- (NSURL *)latestDiarizedTranscriptURL {
    NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:docs
                                                       includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                            error:nil];
    
    NSPredicate *filter = [NSPredicate predicateWithFormat:@"lastPathComponent BEGINSWITH %@", @"merged-transcript-"];
    NSArray *filtered = [contents filteredArrayUsingPredicate:filter];
    
    NSArray *sorted = [filtered sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA, *dateB;
        [a getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
        return [dateB compare:dateA]; // descending
    }];
    
    return sorted.firstObject;
}

- (NSString *)extractTextFromResponsesJSON:(NSDictionary *)json {
    NSMutableString *accum = [NSMutableString string];

    // 1) Easy path: some models include a flat "output_text"
    NSString *ot = json[@"output_text"];
    if ([ot isKindOfClass:NSString.class] && ot.length) {
        [accum appendString:ot];
    }

    // 2) General path: iterate "output" array
    NSArray *output = json[@"output"];
    if ([output isKindOfClass:NSArray.class]) {
        for (id item in output) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *dict = (NSDictionary *)item;

            // 2a) Direct "content" array on the item
            NSArray *content = dict[@"content"];
            if ([content isKindOfClass:NSArray.class]) {
                for (id block in content) {
                    if (![block isKindOfClass:NSDictionary.class]) continue;
                    NSString *t = block[@"text"];
                    if ([t isKindOfClass:NSString.class] && t.length) {
                        [accum appendString:t];
                    }
                }
            }

            // 2b) Sometimes it's nested under "message" → "content"
            NSDictionary *message = dict[@"message"];
            if ([message isKindOfClass:NSDictionary.class]) {
                NSArray *mcontent = message[@"content"];
                if ([mcontent isKindOfClass:NSArray.class]) {
                    for (id block in mcontent) {
                        if (![block isKindOfClass:NSDictionary.class]) continue;
                        NSString *t = block[@"text"];
                        if ([t isKindOfClass:NSString.class] && t.length) {
                            [accum appendString:t];
                        }
                    }
                }
            }

            // 2c) Some servers may also place plain "text" at this level
            NSString *direct = dict[@"text"];
            if ([direct isKindOfClass:NSString.class] && direct.length) {
                [accum appendString:direct];
            }
        }
    }

    // 3) If still empty, try a last-resort scan of any arrays named "content"
    if (!accum.length) {
        id maybeContent = json[@"content"];
        if ([maybeContent isKindOfClass:NSArray.class]) {
            for (id block in (NSArray *)maybeContent) {
                if (![block isKindOfClass:NSDictionary.class]) continue;
                NSString *t = ((NSDictionary *)block)[@"text"];
                if ([t isKindOfClass:NSString.class] && t.length) {
                    [accum appendString:t];
                }
            }
        }
    }

    return accum;
}


- (void)callOpenAIResponsesWithPrompt:(NSString *)prompt {
    NSString *model = self.selectedModel ?: @"gpt-5";
    
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/responses"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";

    NSDictionary *payload = @{
        @"model": model,     // or your specific snapshot, e.g. "gpt-5-2025-08-07"
        @"input": prompt ?: @""
        // IMPORTANT: do NOT include temperature/top_p etc. with many gpt-5 snapshots
    };

    NSString *apiKey = [self loadOpenAIKey];
    if (!apiKey.length) { NSLog(@"❌ Missing API key"); return; }

    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [req addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req addValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSLog(@"❌ Network error: %@", err);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSLog(@"❌ HTTP %ld\n%@", (long)http.statusCode, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            return;
        }

        NSError *jerr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (jerr || ![json isKindOfClass:[NSDictionary class]]) {
            NSLog(@"❌ JSON parse error: %@", jerr);
            return;
        }

        NSLog(@"🧾 Raw response: %@", json);

        NSString *finalText = [self extractTextFromResponsesJSON:json];
        if (!finalText.length) {
            finalText = @"(No text content returned.)";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_textviewResult.text = [NSString stringWithFormat:@"Final Clean Transcript:\n\n%@", finalText];
            self->_labelStatusInp.text = @"Status: Final Result";
            self->_buttonToggleCapture.hidden = NO;
        });
    }] resume];
}


- (IBAction)sendEditedPromptToOpenAI:(id)sender {
    NSString *editedPrompt = self.textviewPrompt.text;
    if (!editedPrompt.length) {
        NSLog(@"⚠️ Prompt is empty, not sending");
        return;
    }

    _labelStatusInp.text = @"Status: Sending to OpenAI";
    _textviewResult.text = @"Sending edited prompt to OpenAI...";
    _textviewPrompt.text = @"";
    [_textviewPrompt setHidden:YES];
    
    [_buttonSendToOpenAI setHidden:YES];
    
    //[self callOpenAIResponsesWithPrompt:editedPrompt];
    [self sendToOpenAIWithPrompt:editedPrompt];
}

- (void)callOpenAIWithPrompt:(NSString *)prompt {
    NSLog(@"Call Open AI With Prompt");
    NSString *model = self.selectedModel ?: @"gpt-5";
    
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    
    NSDictionary *payload = @{
        @"model": model,
        @"messages": @[
            @{@"role": @"system", @"content": @"You are a helpful assistant."},
            @{@"role": @"user", @"content": prompt}
        ],
        @"temperature": @0.3
    };
    
    NSString *apiKey = [self loadOpenAIKey];

    if (!apiKey) {
        NSLog(@"❌ Missing API key — aborting request");
        [_buttonToggleCapture setHidden:NO];
        return;
    }
    
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    request.HTTPBody = body;

    [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    //[request addValue:@"Bearer " forHTTPHeaderField:@"Authorization"];
    [request addValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"❌ OpenAI error: %@", error);
                [_buttonToggleCapture setHidden:NO];
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *result = json[@"choices"][0][@"message"][@"content"];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = [NSString stringWithFormat:@"Final Clean Transcript:\n\n%@", result];
                NSLog(@"✅ Summary received from OpenAI:\n%@", result);
                _labelStatusInp.text = @"Status: Final Result";
                [_buttonToggleCapture setHidden:NO];
            });
        }];
    [task resume];
}



- (NSString *)loadOpenAIKey {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"key" ofType:@"plist"];
    if (!path) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return dict[@"OpenAI_API_Key"];
}

- (void)finishTranscribeResetUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->stateInp.isTranscribing = false;
        self->_labelStatusInp.text = @"Status: Idle";
        self->_buttonToggleCapture.hidden = NO;
        self->_buttonTranscribe.hidden = NO;      // or YES if you want to keep the flow
        self->_buttonTestTranscribe.hidden = YES; // adjust to your UX
        self->_buttonCleanSummarize.hidden = NO;  // or YES depending on flow
    });
}

- (NSString *)hmsFromSeconds:(double)sec {
    if (sec < 0) sec = 0;
    int hours   = (int)floor(sec / 3600.0);
    int minutes = (int)floor(fmod(sec, 3600.0) / 60.0);
    int seconds = (int)floor(fmod(sec, 60.0));
    int millis  = (int)llround((sec - floor(sec)) * 1000.0);
    //return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d", hours, minutes, seconds, millis];
    return [NSString stringWithFormat:@"%02d:%02d:%02d", hours, minutes, seconds];
}

- (void)sendToOpenAIWithPrompt:(NSString *)prompt {
    NSString *model = self.selectedModel ?: @"gpt-5";

    if ([model hasPrefix:@"gpt-4"] || [model hasPrefix:@"gpt-3.5"]) {
        [self callOpenAIWithPrompt:prompt];
    } else if ([model hasPrefix:@"gpt-5"] || [model hasPrefix:@"o"]) {
        [self callOpenAIResponsesWithPrompt:prompt];
    } else {
        NSLog(@"❌ Unsupported model: %@", model);
        _textviewResult.text = [NSString stringWithFormat:@"❌ Unsupported model: %@", model];
    }
}


- (void)configureModelMenu {
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    for (NSString *model in self.availableModels) {
        UIAction *a = [UIAction actionWithTitle:model
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction * _Nonnull action) {
            self.selectedModel = model;
            [self.buttonModel setTitle:[NSString stringWithFormat:@"Model: %@", model]
                              forState:UIControlStateNormal];
            [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"SelectedModel"];
        }];
        [actions addObject:a];
    }

    if (@available(iOS 14.0, *)) {
        self.buttonModel.menu = [UIMenu menuWithTitle:@"Choose Model"
                                              children:actions];
        self.buttonModel.showsMenuAsPrimaryAction = YES; // tap opens menu
    }
}


@end
