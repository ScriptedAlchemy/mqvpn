// SPDX-License-Identifier: Apache-2.0

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void)
{
    char key_path[] = "/tmp/mqvpn-relay-key-XXXXXX";
    int key_fd = mkstemp(key_path);
    if (key_fd < 0) return 2;
    const char *key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n";
    if (write(key_fd, key, strlen(key)) != (ssize_t)strlen(key)) return 2;
    close(key_fd);
    chmod(key_path, 0600);

    char cfg_path[] = "/tmp/mqvpn-relay-config-XXXXXX";
    int cfg_fd = mkstemp(cfg_path);
    if (cfg_fd < 0) return 2;
    char text[1024];
    int n = snprintf(text, sizeof(text),
                     "[Server]\nAddress=198.51.100.10:443\n"
                     "[Relay]\nEnabled=true\nEndpoint=192.168.1.195:5443\n"
                     "KeyFile=%s\n",
                     key_path);
    if (write(cfg_fd, text, (size_t)n) != n) return 2;
    close(cfg_fd);

    mqvpn_file_config_t cfg;
    mqvpn_config_defaults(&cfg);
    int rc = mqvpn_config_load(&cfg, cfg_path);
    unlink(cfg_path);
    unlink(key_path);
    if (rc != -1) {
        fprintf(stderr, "enabled relay accepted in forced non-Apple config build\n");
        return 1;
    }
    return 0;
}
