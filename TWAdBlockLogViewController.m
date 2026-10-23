#import "TWAdBlockLogViewController.h"
#import "TWAdBlockLog.h"

@interface TWAdBlockLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation TWAdBlockLogViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Log";
  self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.textView.editable = NO;
  self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
  self.textView.alwaysBounceVertical = YES;
  [self.view addSubview:self.textView];
  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                  target:self
                                                  action:@selector(share:)],
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                  target:self
                                                  action:@selector(clear)],
  ];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reload];
}
- (void)reload {
  NSString *contents = TWAdBlockLogContents();
  self.textView.text = contents.length ? contents : @"Nothing logged yet.";
  if (contents.length)
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
}
- (void)share:(UIBarButtonItem *)sender {
  // As a file, so a long log isn't cut off by apps that take text
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TwitchAdBlock.log"];
  [TWAdBlockLogContents() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  UIActivityViewController *controller =
      [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
                                        applicationActivities:nil];
  controller.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:controller animated:YES completion:nil];
}
- (void)clear {
  TWAdBlockLogClear();
  [self reload];
}
@end
