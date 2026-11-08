#ifndef HENGEVM_SYSREG_H
#define HENGEVM_SYSREG_H

#include <stdint.h>

#include "cpu.h"

/* MRS, MSR (register and immediate), and SYS (DC, IC, TLBI, AT).
   Each returns 1 if the block must leave. */
int hv_sysreg_mrs(HvCpu *cpu, uint32_t insn, uint64_t pc);
int hv_sysreg_msr(HvCpu *cpu, uint32_t insn, uint64_t pc);
int hv_sysreg_sys(HvCpu *cpu, uint32_t insn, uint64_t pc);

/* The guest's counter (CNTPCT): host mach_absolute_time, which runs at 24 MHz, less hv_time_held. */
uint64_t hv_counter(void);
/* Host ticks the guest was held for (hv_machine_hold). Guest time = host time - this; it only grows,
   and only while no CPU runs guest code. Translated counter reads take it off too (translate_counter). */
extern uint64_t hv_time_held;

/* One TLBI on one CPU's own TLB and branch cache. */
void hv_tlbi_apply(HvCpu *cpu, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt);

#endif
