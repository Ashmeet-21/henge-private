#include "classify.h"

#include <stdio.h>
#include <string.h>

extern const uint32_t hv_classify_cases[];
extern const uint32_t hv_classify_cases_end[];

static const HvInsnKind expected[] = {
    HV_INSN_COPY, HV_INSN_COPY, HV_INSN_COPY, HV_INSN_COPY, HV_INSN_COPY, HV_INSN_COPY,
    HV_INSN_PCREL, HV_INSN_PCREL,
    HV_INSN_BRANCH, HV_INSN_BRANCH, HV_INSN_BRANCH, HV_INSN_BRANCH, HV_INSN_BRANCH,
    HV_INSN_BRANCH_REG, HV_INSN_BRANCH_REG, HV_INSN_BRANCH_REG, HV_INSN_BRANCH_REG,
    HV_INSN_ERET,
    HV_INSN_LOAD_LITERAL, HV_INSN_LOAD_LITERAL,
    HV_INSN_MEMORY, HV_INSN_MEMORY, HV_INSN_MEMORY, HV_INSN_MEMORY, HV_INSN_MEMORY,
    HV_INSN_PREFETCH,
    HV_INSN_EXCEPTION, HV_INSN_EXCEPTION, HV_INSN_EXCEPTION,
    HV_INSN_SYSREG, HV_INSN_SYSREG, HV_INSN_SYSREG,
    HV_INSN_SYS, HV_INSN_SYS,
    HV_INSN_BARRIER, HV_INSN_BARRIER,
    HV_INSN_WAIT,
    HV_INSN_PAC, HV_INSN_PAC, HV_INSN_PAC, HV_INSN_PAC, HV_INSN_PAC,
    HV_INSN_UNDEFINED,
};

int main(void) {
    size_t count = (size_t)(hv_classify_cases_end - hv_classify_cases);
    size_t want = sizeof expected / sizeof expected[0];
    if (count != want) {
        printf("case count %zu does not match %zu expectations\n", count, want);
        return 1;
    }
    int failures = 0;
    for (size_t i = 0; i < count; i++) {
        HvInsnKind got = hv_classify(hv_classify_cases[i]);
        if (got != expected[i]) {
            printf("case %zu: %08x is %s, expected %s\n", i, hv_classify_cases[i],
                   hv_insn_kind_name(got), hv_insn_kind_name(expected[i]));
            failures++;
        }
    }
    /* Words with 0xfe or 0xff on top are unallocated (SIMD and FP op0 1111): an opaque pixel run as code must
       raise the guest's undefined instruction, not be copied to the host. Real SIMD and FP code is still copied. */
    static const struct { uint32_t insn; HvInsnKind kind; } more[] = {
        {0xfff4f4f4, HV_INSN_UNDEFINED}, {0xffffffff, HV_INSN_UNDEFINED}, {0xfefefefe, HV_INSN_UNDEFINED},
        {0xfe000000, HV_INSN_UNDEFINED}, {0x4e208400, HV_INSN_COPY} /* add v0.16b */, {0x1e220020, HV_INSN_COPY} /* scvtf */,
        {0x9e220020, HV_INSN_COPY} /* scvtf s0, x1 */, {0xce608c00, HV_INSN_COPY} /* rax1 */,
    };
    for (size_t i = 0; i < sizeof more / sizeof more[0]; i++) {
        HvInsnKind got = hv_classify(more[i].insn);
        if (got != more[i].kind) {
            printf("%08x is %s, expected %s\n", more[i].insn, hv_insn_kind_name(got), hv_insn_kind_name(more[i].kind));
            failures++;
        }
    }
    printf("%zu cases, %d failures\n", count, failures);
    return failures != 0;
}
