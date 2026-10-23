#import "Settings.h"

extern NSUserDefaults *tweakDefaults;

@interface _TtC6Twitch25AccountMenuViewController (TwitchAdBlock)
- (BOOL)twab_isAdBlockRowAtIndexPath:(NSIndexPath *)indexPath tableView:(UITableView *)tableView;
@end

%hook _TtC6Twitch25AccountMenuViewController
%new
- (BOOL)twab_isAdBlockRowAtIndexPath:(NSIndexPath *)indexPath tableView:(UITableView *)tableView {
  return indexPath.section == [self numberOfSectionsInTableView:tableView] - 1 &&
         indexPath.row == [self tableView:tableView numberOfRowsInSection:indexPath.section] - 1;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if ([self twab_isAdBlockRowAtIndexPath:indexPath tableView:tableView]) {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewStyle tableViewStyle = UITableViewStyleGrouped;
    if (@available(iOS 13, *)) tableViewStyle = UITableViewStyleInsetGrouped;
    return [self.navigationController
        pushViewController:[[TWAdBlockSettingsViewController alloc] initWithStyle:tableViewStyle]
                  animated:YES];
  }
  %orig;
}
// The app indexes its own row model here, which doesn't contain our extra row
- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if ([self twab_isAdBlockRowAtIndexPath:indexPath tableView:tableView]) return;
  %orig;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  NSInteger numberOfRows = %orig;
  if (section == [self numberOfSectionsInTableView:tableView] - 1) numberOfRows++;
  return numberOfRows;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (![self twab_isAdBlockRowAtIndexPath:indexPath tableView:tableView]) return %orig;
  Class cellClass = objc_getClass("_TtC6Twitch34ConfigurableAccessoryTableViewCell");
  if (!cellClass) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.textLabel.text = @"TwitchAdBlock";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  _TtC6Twitch34ConfigurableAccessoryTableViewCell *cell =
      [[cellClass alloc] initWithStyle:UITableViewCellStyleSubtitle
                       reuseIdentifier:@"Twitch.ConfigurableAccessoryTableViewCell"];
  [cell configureWithTitle:@"TwitchAdBlock"];
  if ([cell respondsToSelector:@selector(setUseDefaultBackgroundColor:)])
    cell.useDefaultBackgroundColor = YES;
  NSBundle *twCoreUIBundle = [NSBundle bundleWithIdentifier:@"twitch.TwitchCoreUI"];
  UIImage *arrowImage = [UIImage imageNamed:@"arrow-forward-Icon"
                                   inBundle:twCoreUIBundle
              compatibleWithTraitCollection:nil];
  UIImage *iconImage = [UIImage imageNamed:@"Un-Host-Icon"
                                  inBundle:twCoreUIBundle
             compatibleWithTraitCollection:nil];
  if (@available(iOS 13, *)) {
    if (!arrowImage) arrowImage = [UIImage systemImageNamed:@"chevron.right"];
    if (!iconImage) iconImage = [UIImage systemImageNamed:@"nosign"];
  }
  UIImageView *arrowView = [[UIImageView alloc] initWithImage:arrowImage];
  arrowView.tintColor = UIColor.grayColor;
  cell.accessoryView = arrowView;
  Ivar customImageViewIvar = class_getInstanceVariable(object_getClass(cell), "customImageView");
  if (!customImageViewIvar) return cell;
  UIImageView *customImageView = object_getIvar(cell, customImageViewIvar);
  customImageView.image = iconImage;
  customImageView.hidden = NO;
  return cell;
}
%end
