#import "TWAdBlockSettingsViewController.h"
#import "TWAdBlockLogViewController.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;

#define LOC(x, d) [tweakBundle localizedStringForKey:x value:d table:nil]

static NSString *const kEnabledKey = @"TWAdBlockEnabled";
static NSString *const kProxyKey = @"TWAdBlockProxyEnabled";
static NSString *const kCustomProxyKey = @"TWAdBlockCustomProxyEnabled";
static NSString *const kDebugLogKey = @"TWAdBlockDebugLog";

@implementation TWAdBlockSettingsViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"TwitchAdBlock";
}
- (NSInteger)debugSection {
  return [tweakDefaults boolForKey:kEnabledKey] ? 2 : 1;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return self.debugSection + 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == 0) return 1;
  if (section == self.debugSection) return 2;
  if (![tweakDefaults boolForKey:kProxyKey]) return 1;
  return [tweakDefaults boolForKey:kCustomProxyKey] ? 3 : 2;
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
  if (indexPath.section == self.debugSection) {
    if (indexPath.row == 0) return [self switchCellWithTitle:@"Ad Detection Log" key:kDebugLogKey];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.textLabel.text = @"View Log";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  if (indexPath.row == 0)
    return [self switchCellWithTitle:LOC(@"settings.proxy.title", @"Ad Block Proxy")
                                 key:kProxyKey];
  if (indexPath.row == 1)
    return [self switchCellWithTitle:LOC(@"settings.custom_proxy.title", @"Custom Proxy")
                                 key:kCustomProxyKey];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  UITextField *textField = [[UITextField alloc] init];
  textField.translatesAutoresizingMaskIntoConstraints = NO;
  textField.placeholder = PROXY_ADDR;
  textField.text = [tweakDefaults stringForKey:@"TWAdBlockProxy"];
  textField.keyboardType = UIKeyboardTypeURL;
  textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  textField.autocorrectionType = UITextAutocorrectionTypeNo;
  textField.spellCheckingType = UITextSpellCheckingTypeNo;
  textField.returnKeyType = UIReturnKeyDone;
  textField.clearButtonMode = UITextFieldViewModeWhileEditing;
  textField.delegate = self;
  [cell.contentView addSubview:textField];
  UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [textField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
    [textField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    [textField.topAnchor constraintEqualToAnchor:margins.topAnchor],
    [textField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
  ]];
  return cell;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  NSString *title;
  if (section == 0)
    title = LOC(@"settings.adblock.footer", @"Choose whether or not you want to block ads");
  else if (section == self.debugSection)
    title = @"Records the stream tokens, playlists and ad breaks the player sees, to test ad "
            @"blocking. Playlists aren't recorded while the proxy is on.";
  else
    title = LOC(@"settings.proxy.footer",
                @"Proxy specific requests through a proxy server based in an ad-free country");
  if (section == [self numberOfSectionsInTableView:tableView] - 1)
    title = [title stringByAppendingString:@"\n\nTwitchAdBlock v" PACKAGE_VERSION];
  return title;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == self.debugSection && indexPath.row == 1)
    [self.navigationController pushViewController:[[TWAdBlockLogViewController alloc] init]
                                         animated:YES];
}
- (void)switchToggled:(UISwitch *)sender {
  [self.view endEditing:YES];
  [tweakDefaults setBool:sender.isOn forKey:sender.accessibilityIdentifier];
  [tweakDefaults synchronize];
  [self.tableView reloadData];
}
- (void)textFieldDidEndEditing:(UITextField *)textField {
  [tweakDefaults setObject:textField.text forKey:@"TWAdBlockProxy"];
  [tweakDefaults synchronize];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  return [textField resignFirstResponder];
}
@end
