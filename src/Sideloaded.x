// https://github.com/PoomSmart/IAmYouTube/blob/main/Tweak.x
// Allows low latency player while sideloaded

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "fishhook/fishhook.h"

#ifndef TW_BUNDLE_ID
#define TW_BUNDLE_ID @"tv.twitch"
#endif
#define TW_NAME @"Twitch"

%hook NSBundle

- (NSString *)bundleIdentifier {
  NSArray *address = [NSThread callStackReturnAddresses];
  Dl_info info;
  if (dladdr((void *)[address[2] longLongValue], &info) == 0) return %orig;
  NSString *path = [NSString stringWithUTF8String:info.dli_fname];
  if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) return TW_BUNDLE_ID;
  return %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
  if ([key isEqualToString:@"CFBundleIdentifier"]) return TW_BUNDLE_ID;
  if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"])
    return TW_NAME;
  return %orig;
}

%end

// https://github.com/opa334/IGSideloadFix

static NSString *keychainAccessGroup;
static NSURL *fakeGroupContainerURL;

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
  NSURL *fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];
  // Also creates fakeURL and Library; does nothing when they exist
  [NSFileManager.defaultManager createDirectoryAtURL:[fakeURL URLByAppendingPathComponent:@"Library/Caches"]
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  return fakeURL;
}

%end

static void loadKeychainAccessGroup(void) {
  NSDictionary *dummyItem = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrAccount : @"dummyItem",
    (__bridge id)kSecAttrService : @"dummyService",
    (__bridge id)kSecReturnAttributes : @YES,
  };
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
  if (status == errSecItemNotFound) status = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);
  NSDictionary *attributes = CFBridgingRelease(result);
  if (status == errSecSuccess) keychainAccessGroup = attributes[(__bridge id)kSecAttrAccessGroup];
}

// A copy of query with the app's own access group in place of the one it asked for (a sideloaded
// app can't use the original's), or NULL when there's nothing to replace. Release it after use.
static CFDictionaryRef copyWithAccessGroup(CFDictionaryRef query) {
  if (!keychainAccessGroup || !CFDictionaryContainsKey(query, kSecAttrAccessGroup)) return NULL;
  CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
  CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)keychainAccessGroup);
  return copy;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  CFDictionaryRef fixed = copyWithAccessGroup(attributes);
  OSStatus status = orig_SecItemAdd(fixed ?: attributes, result);
  if (fixed) CFRelease(fixed);
  return status;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  CFDictionaryRef fixed = copyWithAccessGroup(query);
  OSStatus status = orig_SecItemCopyMatching(fixed ?: query, result);
  if (fixed) CFRelease(fixed);
  return status;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
  CFDictionaryRef fixed = copyWithAccessGroup(query);
  OSStatus status = orig_SecItemUpdate(fixed ?: query, attributesToUpdate);
  if (fixed) CFRelease(fixed);
  return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
  CFDictionaryRef fixed = copyWithAccessGroup(query);
  OSStatus status = orig_SecItemDelete(fixed ?: query);
  if (fixed) CFRelease(fixed);
  return status;
}

%ctor {
  // Before %init, so the NSFileManager hook never sees it nil
  fakeGroupContainerURL = [NSURL
      fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"]
          isDirectory:YES];
  %init;
  loadKeychainAccessGroup();
  rebind_symbols(
      (struct rebinding[]){
          {"SecItemAdd", (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd},
          {"SecItemCopyMatching", (void *)hook_SecItemCopyMatching,
           (void **)&orig_SecItemCopyMatching},
          {"SecItemUpdate", (void *)hook_SecItemUpdate, (void **)&orig_SecItemUpdate},
          {"SecItemDelete", (void *)hook_SecItemDelete, (void **)&orig_SecItemDelete},
      },
      4);
}
