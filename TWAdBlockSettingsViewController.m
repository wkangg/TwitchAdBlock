#import "TWAdBlockSettingsViewController.h"
#import "TWAdBlockLogViewController.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;

#define LOC(x, d) [tweakBundle localizedStringForKey:x value:d table:nil]

static NSString *const kEnabledKey = @"TWAdBlockEnabled";
static NSString *const kDebugLogKey = @"TWAdBlockDebugLog";

@implementation TWAdBlockSettingsViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"TwitchAdBlock";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 1 : 2;
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
  return @"Records the stream tokens, playlists and ad breaks the player sees, to test ad "
         @"blocking.\n\nTwitchAdBlock v" PACKAGE_VERSION;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == 1 && indexPath.row == 1)
    [self.navigationController pushViewController:[[TWAdBlockLogViewController alloc] init]
                                         animated:YES];
}
- (void)switchToggled:(UISwitch *)sender {
  [tweakDefaults setBool:sender.isOn forKey:sender.accessibilityIdentifier];
  [tweakDefaults synchronize];
}
@end
