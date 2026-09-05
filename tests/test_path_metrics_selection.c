// SPDX-License-Identifier: Apache-2.0
#include "path_metrics_selection.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

int main(void)
{
    xqc_path_metrics_t paths[16] = {0};
    size_t indices[9];
    for (size_t i = 0; i < 16; i++) {
        paths[i].path_id = i;
        paths[i].path_state = i < 8 ? MQVPN_XQC_PATH_STATE_CLOSED
                                    : MQVPN_XQC_PATH_STATE_ACTIVE;
    }
    indices[8] = 999;
    CHECK(mqvpn_select_path_metrics(paths, 16, indices, 8) == 8);
    for (size_t i = 0; i < 8; i++) CHECK(paths[indices[i]].path_id == i + 8);
    CHECK(indices[8] == 999);
    paths[0].path_state = MQVPN_XQC_PATH_STATE_VALIDATING;
    CHECK(mqvpn_select_path_metrics(paths, 16, indices, 9) == 9);
    CHECK(indices[8] == 0);
    CHECK(mqvpn_select_path_metrics(paths, 3, indices, 8) == 3);
    CHECK(indices[0] == 0 && indices[1] == 1 && indices[2] == 2);
    CHECK(mqvpn_select_path_metrics(NULL, 16, indices, 8) == 0);
    CHECK(mqvpn_select_path_metrics(paths, 0, indices, 8) == 0);
    CHECK(mqvpn_select_path_metrics(paths, 16, indices, 0) == 0);
    puts("path metrics: migration, priority, history, and bounds PASS");
    return 0;
}
