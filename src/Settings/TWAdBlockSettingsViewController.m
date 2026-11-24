#import "TWAdBlockSettingsViewController.h"
#import "TWAdBlockLogViewController.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;

#define LOC(x, d) [tweakBundle localizedStringForKey:x value:d table:nil]

static NSString *const kEnabledKey = @"TWAdBlockEnabled";
static NSString *const kHidePromotionsKey = @"TWAdBlockHidePromotions";
static NSString *const kDebugLogKey = @"TWAdBlockDebugLog";

@implementation TWAdBlockSettingsViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"TwitchAdBlock";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 3;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 2 ? 2 : 1;
}
- (UITableViewCell *)switchCellWithTitle:(NSString *)title key:(NSString *)key {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
  cell.textLabel.text = title;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  UISwitch *switchView = [[UISwitch alloc] init];
  switchView.on = [tweakDefaults boolForKey:key];
  switchView.accessibilityIdentifier = key;
  [switchView addTarget:self
                 action:@selector(switchToggled:)
       forControlEvents:UIControlEventValueChanged];
  cell.accessoryView = switchView;
  return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == 0)
    return [self switchCellWithTitle:LOC(@"settings.adblock.title", @"Ad Block") key:kEnabledKey];
  if (indexPath.section == 1)
    return [self switchCellWithTitle:LOC(@"settings.hidepromotions.title", @"Hide Promotions")
                                 key:kHidePromotionsKey];
  if (indexPath.row == 0) return [self switchCellWithTitle:@"Ad Detection Log" key:kDebugLogKey];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
  cell.textLabel.text = @"View Log";
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section == 0)
    return LOC(@"settings.adblock.footer", @"Choose whether or not you want to block ads");
  if (section == 1)
    return LOC(@"settings.hidepromotions.footer",
               @"Hides sponsor banners under the player and the \"Try Ad-Free\" Turbo button");
  return @"Records the stream tokens, playlists and ad breaks the player sees, to test ad "
         @"blocking.\n\nTwitchAdBlock v" PACKAGE_VERSION @" (" GIT_COMMIT @")";
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == 2 && indexPath.row == 1)
    [self.navigationController pushViewController:[[TWAdBlockLogViewController alloc] init]
                                         animated:YES];
}
- (void)switchToggled:(UISwitch *)sender {
  [tweakDefaults setBool:sender.isOn forKey:sender.accessibilityIdentifier];
  [tweakDefaults synchronize];
}
@end
