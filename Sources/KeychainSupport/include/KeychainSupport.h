#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>

// Suppresses login-Keychain prompts for background reads. Explicit reads keep
// the process's existing interaction policy. No access controls are changed.
OSStatus F1CopyKeychainItem(CFDictionaryRef query, bool allowingInteraction,
                          CFTypeRef * CF_RETURNS_RETAINED result);
