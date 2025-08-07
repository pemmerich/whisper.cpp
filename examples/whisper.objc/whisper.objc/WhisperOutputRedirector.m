// WhisperOutputRedirector.m
#import "WhisperOutputRedirector.h"

static FILE *originalStdout = NULL;

@implementation WhisperOutputRedirector

+ (void)redirectStdoutToFileAtPath:(NSString *)filePath {
    if (originalStdout == NULL) {
        originalStdout = fdopen(dup(STDOUT_FILENO), "a+");
    }

    freopen([filePath UTF8String], "w+", stdout);
    setbuf(stdout, NULL); // Disable buffering
}

+ (void)restoreStdout {
    if (originalStdout != NULL) {
        fflush(stdout);
        dup2(fileno(originalStdout), STDOUT_FILENO);
        fclose(originalStdout);
        originalStdout = NULL;
    }
}

@end
