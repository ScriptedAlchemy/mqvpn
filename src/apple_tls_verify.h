// SPDX-License-Identifier: Apache-2.0

#ifndef MQVPN_APPLE_TLS_VERIFY_H
#define MQVPN_APPLE_TLS_VERIFY_H

#include <stddef.h>

typedef int (*mqvpn_apple_tls_evaluator_fn)(const unsigned char *const certs[],
                                            const size_t cert_len[], size_t certs_len,
                                            const char *hostname);

int mqvpn_apple_tls_verify_server_chain(const unsigned char *const certs[],
                                        const size_t cert_len[], size_t certs_len,
                                        const char *hostname);

#ifdef MQVPN_API_TEST_SEAM
void mqvpn_apple_tls_set_evaluator_for_test(mqvpn_apple_tls_evaluator_fn evaluator);
#endif

#endif
