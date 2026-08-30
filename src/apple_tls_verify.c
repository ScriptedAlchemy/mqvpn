// SPDX-License-Identifier: Apache-2.0

#include "apple_tls_verify.h"

#if !defined(__APPLE__)
#  error "apple_tls_verify.c must only be compiled for Apple platforms"
#endif

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <limits.h>

#define MQVPN_APPLE_TLS_MAX_CHAIN_LENGTH 32u

static int
evaluate_with_system_trust(const unsigned char *const certs[], const size_t cert_len[],
                           size_t certs_len, const char *hostname)
{
    int result = -1;
    CFMutableArrayRef chain = NULL;
    CFStringRef hostname_string = NULL;
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    CFErrorRef error = NULL;

    chain = CFArrayCreateMutable(kCFAllocatorDefault, (CFIndex)certs_len,
                                 &kCFTypeArrayCallBacks);
    if (!chain) goto cleanup;

    for (size_t i = 0; i < certs_len; i++) {
        CFDataRef der = CFDataCreate(kCFAllocatorDefault, certs[i], (CFIndex)cert_len[i]);
        if (!der) goto cleanup;
        SecCertificateRef certificate =
            SecCertificateCreateWithData(kCFAllocatorDefault, der);
        CFRelease(der);
        if (!certificate) goto cleanup;
        CFArrayAppendValue(chain, certificate);
        CFRelease(certificate);
    }

    hostname_string =
        CFStringCreateWithCString(kCFAllocatorDefault, hostname, kCFStringEncodingUTF8);
    if (!hostname_string) goto cleanup;
    policy = SecPolicyCreateSSL(true, hostname_string);
    if (!policy) goto cleanup;
    if (SecTrustCreateWithCertificates(chain, policy, &trust) != errSecSuccess || !trust)
        goto cleanup;
    if (!SecTrustEvaluateWithError(trust, &error)) goto cleanup;
    result = 0;

cleanup:
    if (error) CFRelease(error);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (hostname_string) CFRelease(hostname_string);
    if (chain) CFRelease(chain);
    return result;
}

#ifdef MQVPN_API_TEST_SEAM
static mqvpn_apple_tls_evaluator_fn s_test_evaluator;

void
mqvpn_apple_tls_set_evaluator_for_test(mqvpn_apple_tls_evaluator_fn evaluator)
{
    s_test_evaluator = evaluator;
}
#endif

int
mqvpn_apple_tls_verify_server_chain(const unsigned char *const certs[],
                                    const size_t cert_len[], size_t certs_len,
                                    const char *hostname)
{
    if (!certs || !cert_len || !hostname || !hostname[0] || certs_len == 0 ||
        certs_len > MQVPN_APPLE_TLS_MAX_CHAIN_LENGTH)
        return -1;
    for (size_t i = 0; i < certs_len; i++) {
        if (!certs[i] || cert_len[i] == 0 || cert_len[i] > (size_t)LONG_MAX) return -1;
    }

#ifdef MQVPN_API_TEST_SEAM
    if (s_test_evaluator) return s_test_evaluator(certs, cert_len, certs_len, hostname);
#endif
    return evaluate_with_system_trust(certs, cert_len, certs_len, hostname);
}
