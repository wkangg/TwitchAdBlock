#import <Foundation/Foundation.h>

// Debug log shown in the settings screen. Does nothing unless TWAdBlockDebugLog is on.
BOOL TWAdBlockLogEnabled(void);
void TWAdBlockLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *TWAdBlockLogContents(void);
void TWAdBlockLogClear(void);
