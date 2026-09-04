#include "KeychainSupport.h"
#include <pthread.h>

static pthread_mutex_t interactionLock = PTHREAD_MUTEX_INITIALIZER;

// LAContext.interactionNotAllowed only covers the data-protection Keychain.
// Our existing login-Keychain items need this legacy API. Keep its process-wide
// setting scoped to one synchronous read, serialize reads, and restore it even
// on failure. The authentication actor also serializes reads with saves/removes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus F1CopyKeychainItem(CFDictionaryRef query, bool allowingInteraction,
                          CFTypeRef *result) {
    pthread_mutex_lock(&interactionLock);
    Boolean previous = false;
    bool changed = false;
    OSStatus status = errSecSuccess;
    if (!allowingInteraction) {
        status = SecKeychainGetUserInteractionAllowed(&previous);
        if (status == errSecSuccess && previous) {
            status = SecKeychainSetUserInteractionAllowed(false);
            changed = status == errSecSuccess;
        }
    }
    if (status == errSecSuccess) {
        status = SecItemCopyMatching(query, result);
    }
    if (changed) {
        OSStatus restored = SecKeychainSetUserInteractionAllowed(previous);
        if (restored != errSecSuccess) { status = restored; }
    }
    pthread_mutex_unlock(&interactionLock);
    return status;
}
#pragma clang diagnostic pop
