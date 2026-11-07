#ifndef HENGEVM_PVG_DECODE_H
#define HENGEVM_PVG_DECODE_H

#include <stdbool.h>
#include <stdint.h>

/* Validate a packed binding record and the destination slot range without
   overflowing index + count or header + count * element. Empty arrays may
   begin at limit, but still require their complete header. */
static inline bool hv_pvg_payload_array_valid(uint64_t payload, uint64_t header,
                                              uint64_t element, uint64_t index,
                                              uint64_t count, uint64_t limit) {
    if (index > limit || count > limit - index || header > payload) return false;
    return element == 0 || count <= (payload - header) / element;
}

/* A buffer access may end exactly at length. The subtraction and division
   avoid overflow even when the guest supplies near-UINT64_MAX parameters.
   A zero element stride is not a meaningful buffer span. */
static inline bool hv_pvg_buffer_span_valid(uint64_t length, uint64_t offset,
                                            uint64_t count, uint64_t stride) {
    return stride != 0 && offset <= length && count <= (length - offset) / stride;
}

/* Minimum payload bytes read by the existing replay draw handlers, excluding
   the eight-byte {tag, size} record header. These retain the current guest wire
   formats; they do not infer or change the meaning of any draw parameter.
   Zero means that this helper does not describe the tag. */
static inline uint32_t hv_pvg_draw_payload_min(uint32_t tag) {
    static const uint8_t minimum[20] = {
        20, 8, 26, 8, 34, 10, 24, 12, 32, 14,
        48, 18, 46, 16, 58, 22, 16, 28, 26, 38
    };
    if (tag < 20) return minimum[tag];
    if (tag == 28) return 48;
    if (tag == 29) return 18;
    return 0;
}

#endif
