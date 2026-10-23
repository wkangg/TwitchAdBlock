#import <UIKit/UIKit.h>
#import "Config.h"

// Plain UIKit so it doesn't depend on TwitchCoreUI internals, which change between app versions
@interface TWAdBlockSettingsViewController : UITableViewController <UITextFieldDelegate>
@end
