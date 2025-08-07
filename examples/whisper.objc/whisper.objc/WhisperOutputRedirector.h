// WhisperOutputRedirector.h
#import <Foundation/Foundation.h>

@interface WhisperOutputRedirector : NSObject

+ (void)redirectStdoutToFileAtPath:(NSString *)filePath;
+ (void)restoreStdout;

@end
