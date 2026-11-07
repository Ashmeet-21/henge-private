#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include "pvg_decode.h"

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return EXIT_FAILURE; \
    } \
} while (0)

int main(void) {
    /* Vertex binding tag 125: two {ref:u32, offset:u64} entries at slot 29. */
    CHECK(hv_pvg_payload_array_valid(32, 8, 12, 29, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(31, 8, 12, 29, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(32, 8, 12, 30, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(7, 8, 12, 0, 0, 31));
    CHECK(hv_pvg_payload_array_valid(8, 8, 12, 31, 0, 31));
    CHECK(!hv_pvg_payload_array_valid(8, 8, 12, 32, 0, 31));

    /* Dynamic strides occupy twenty packed bytes per binding. A record that
       merely contains the first binding must never expose the next record. */
    CHECK(hv_pvg_payload_array_valid(48, 8, 20, 0, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(28, 8, 20, 0, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(UINT64_MAX, 8, UINT64_MAX, 0, 2, 31));
    CHECK(!hv_pvg_payload_array_valid(UINT64_MAX, 8, 12, UINT64_MAX, 2, UINT64_MAX));
    CHECK(!hv_pvg_payload_array_valid(UINT64_MAX, 8, 12, 0, UINT64_MAX, UINT64_MAX));
    CHECK(hv_pvg_payload_array_valid(UINT64_MAX, 0, 1, 0, UINT64_MAX, UINT64_MAX));
    CHECK(hv_pvg_payload_array_valid(8, 8, 0, 0, 2, 31));

    /* uint16 and uint32 index spans, including a nonzero buffer offset. */
    CHECK(hv_pvg_buffer_span_valid(64, 4, 30, 2));
    CHECK(!hv_pvg_buffer_span_valid(64, 4, 31, 2));
    CHECK(hv_pvg_buffer_span_valid(64, 4, 15, 4));
    CHECK(!hv_pvg_buffer_span_valid(64, 4, 16, 4));
    CHECK(hv_pvg_buffer_span_valid(64, 64, 0, 4));
    CHECK(!hv_pvg_buffer_span_valid(64, 65, 0, 4));
    CHECK(!hv_pvg_buffer_span_valid(64, 0, 1, 0));
    CHECK(!hv_pvg_buffer_span_valid(UINT64_MAX, UINT64_MAX - 3, 1, 4));
    CHECK(!hv_pvg_buffer_span_valid(UINT64_MAX, 0, UINT64_MAX, 4));
    CHECK(hv_pvg_buffer_span_valid(UINT64_MAX, 0, UINT64_MAX, 1));

    /* Native indirect structures require sixteen or twenty bytes. */
    CHECK(hv_pvg_buffer_span_valid(32, 16, 1, 16));
    CHECK(!hv_pvg_buffer_span_valid(31, 16, 1, 16));
    CHECK(hv_pvg_buffer_span_valid(36, 16, 1, 20));
    CHECK(!hv_pvg_buffer_span_valid(35, 16, 1, 20));

    /* Regression anchors for compact, wide and signed-base-vertex records. */
    CHECK(hv_pvg_draw_payload_min(0) == 20);
    CHECK(hv_pvg_draw_payload_min(1) == 8);
    CHECK(hv_pvg_draw_payload_min(10) == 48);
    CHECK(hv_pvg_draw_payload_min(11) == 18);
    CHECK(hv_pvg_draw_payload_min(14) == 58);
    CHECK(hv_pvg_draw_payload_min(17) == 28);
    CHECK(hv_pvg_draw_payload_min(28) == 48);
    CHECK(hv_pvg_draw_payload_min(29) == 18);
    for (uint32_t tag = 0; tag < 20; tag++) {
        uint64_t bytes = hv_pvg_draw_payload_min(tag);
        CHECK(bytes != 0);
        CHECK(!hv_pvg_payload_array_valid(bytes - 1, bytes, 0, 0, 0, 0));
        CHECK(hv_pvg_payload_array_valid(bytes, bytes, 0, 0, 0, 0));
    }
    CHECK(hv_pvg_draw_payload_min(20) == 0);
    CHECK(hv_pvg_draw_payload_min(UINT32_MAX) == 0);
    puts("PASS: PVG packed payload, binding slot and buffer span boundaries");
    return EXIT_SUCCESS;
}
