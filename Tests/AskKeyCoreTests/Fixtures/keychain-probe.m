#import <CoreFoundation/CoreFoundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static CFMutableDictionaryRef query(const char *serviceBytes, const char *groupBytes) {
    CFStringRef service = CFStringCreateWithCString(
        kCFAllocatorDefault,
        serviceBytes,
        kCFStringEncodingUTF8
    );
    CFStringRef group = CFStringCreateWithCString(
        kCFAllocatorDefault,
        groupBytes,
        kCFStringEncodingUTF8
    );
    if (service == NULL || group == NULL) return NULL;
    LAContext *context = [[LAContext alloc] init];
    context.interactionNotAllowed = YES;
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(result, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(result, kSecAttrService, service);
    CFDictionarySetValue(result, kSecAttrAccount, CFSTR("vault-key"));
    if (strcmp(groupBytes, "-") != 0) {
        CFDictionarySetValue(result, kSecAttrAccessGroup, group);
    }
    CFDictionarySetValue(result, kSecUseAuthenticationContext, (__bridge const void *)context);
    CFDictionarySetValue(result, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    CFRelease(service);
    CFRelease(group);
    return result;
}

int main(int argc, const char *argv[]) {
    if (argc < 4) return 64;
    CFMutableDictionaryRef itemQuery = query(argv[2], argv[3]);
    if (itemQuery == NULL) return 65;
    if (strcmp(argv[1], "policy") == 0) {
        const void *policy = CFDictionaryGetValue(itemQuery, kSecUseAuthenticationUI);
        bool failsWithoutUI = policy != NULL && CFEqual(policy, kSecUseAuthenticationUIFail);
        CFRelease(itemQuery);
        return failsWithoutUI ? 0 : 1;
    }
    CFTypeRef result = NULL;
    OSStatus status;
    if (strcmp(argv[1], "read") == 0) {
        const char *testPrefix = "com.sudohg.askkey.tests.missing.";
        if (strncmp(argv[2], testPrefix, strlen(testPrefix)) != 0) {
            CFRelease(itemQuery);
            return 67;
        }
        CFDictionarySetValue(itemQuery, kSecReturnData, kCFBooleanTrue);
        CFDictionarySetValue(itemQuery, kSecMatchLimit, kSecMatchLimitOne);
        status = SecItemCopyMatching(itemQuery, &result);
    } else {
        return 64;
    }
    if (status == errSecSuccess && result != NULL) {
        CFDataRef data = (CFDataRef)result;
        fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), stdout);
    }
    if (result != NULL) CFRelease(result);
    CFRelease(itemQuery);
    return status == errSecSuccess ? 0 : 1;
}
