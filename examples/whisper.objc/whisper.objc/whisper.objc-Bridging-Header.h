//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//
#import <Foundation/Foundation.h>

@interface FluidDiarizerResult : NSObject
@property (nonatomic) NSInteger speakerId;
@property (nonatomic) double startTimeSeconds;
@property (nonatomic) double endTimeSeconds;
@end

__attribute__((swift_name("DiarizerManager")))
@interface DiarizerManager : NSObject
- (void)initializeWithCompletion:(void (^)(NSError *_Nullable))completion;
- (void)performCompleteDiarizationWithSamples:(NSData *)samples
                                  sampleRate:(int)sampleRate
                                   completion:(void (^)(NSArray<FluidDiarizerResult *> *_Nullable, NSError *_Nullable))completion;
@end

