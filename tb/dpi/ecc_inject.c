/*
 * File   : tb/dpi/ecc_inject.c
 * Purpose: DPI-C implementation of ECC fault injection for UVM directed tests.
 *          Called from l2_ecc_test.sv to flip bits in the simulated SRAM.
 *
 * Functions:
 *   ecc_inject_fault(addr, bit_position, double_error)
 *     → Registers a pending fault for the next SRAM read at 'addr'.
 *       The simulation PLI hook intercepts the SRAM read and flips the bit.
 *
 *   ecc_clear_faults()
 *     → Clears all pending fault registrations.
 *
 *   ecc_get_fault_count()
 *     → Returns number of faults injected since last clear.
 *
 * Build: compiled automatically by VCS as DPI shared object.
 *        VCS flag: -sv_lib tb/dpi/ecc_inject
 *        GCC:      gcc -fPIC -shared -o ecc_inject.so ecc_inject.c \
 *                      -I$VCS_HOME/include
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "svdpi.h"

/* ── Fault table ──────────────────────────────────────────────────────────── */
#define MAX_FAULTS 64

typedef struct {
    uint64_t  addr;           /* target address (byte-aligned to 8B) */
    int       bit_position;   /* bit to flip (0–63) */
    int       double_error;   /* 1 = also flip bit_position+1 */
    int       active;         /* 1 = fault registered, not yet consumed */
    int       consumed;       /* 1 = fault was triggered during simulation */
} fault_entry_t;

static fault_entry_t fault_table[MAX_FAULTS];
static int fault_count = 0;
static int faults_consumed = 0;

/* ── DPI exported functions ─────────────────────────────────────────────── */

/* Register a fault for the next SRAM read at 'addr' */
DPI_DLLESPEC int ecc_inject_fault(
    long long addr,
    int       bit_position,
    svBit     double_error
) {
    if (fault_count >= MAX_FAULTS) {
        fprintf(stderr, "[ECC_DPI] ERROR: fault table full\n");
        return -1;
    }
    if (bit_position < 0 || bit_position > 63) {
        fprintf(stderr, "[ECC_DPI] ERROR: bit_position %d out of range\n",
                bit_position);
        return -1;
    }

    fault_entry_t *f = &fault_table[fault_count++];
    f->addr         = (uint64_t)addr & ~0x7ULL;  /* align to 8B */
    f->bit_position = bit_position;
    f->double_error = (int)double_error;
    f->active       = 1;
    f->consumed     = 0;

    printf("[ECC_DPI] Fault registered: addr=0x%llx bit=%d %s\n",
           (unsigned long long)f->addr, bit_position,
           double_error ? "(double)" : "(single)");
    return 0;
}

/* Clear all registered faults */
DPI_DLLESPEC void ecc_clear_faults(void) {
    memset(fault_table, 0, sizeof(fault_table));
    fault_count    = 0;
    faults_consumed= 0;
    printf("[ECC_DPI] All faults cleared\n");
}

/* Return number of faults consumed (triggered) */
DPI_DLLESPEC int ecc_get_fault_count(void) {
    return faults_consumed;
}

/*
 * ecc_apply_fault — called by the simulation model on every SRAM read.
 * Returns 1 if a fault was applied (bit flip done), 0 otherwise.
 * The caller is responsible for flipping the data word before returning it.
 */
DPI_DLLESPEC int ecc_apply_fault(
    long long      addr,
    /* inout */ svLogicVecVal *data   /* 64-bit word to potentially corrupt */
) {
    uint64_t byte_addr = (uint64_t)addr & ~0x7ULL;

    for (int i = 0; i < fault_count; i++) {
        fault_entry_t *f = &fault_table[i];
        if (f->active && !f->consumed && f->addr == byte_addr) {
            /* Flip the target bit */
            int   word_half = f->bit_position / 32;
            int   bit_in_half = f->bit_position % 32;
            uint32_t mask = (1U << bit_in_half);

            if (word_half == 0)
                data[0].aval ^= mask;
            else
                data[1].aval ^= mask;

            /* Double error: flip an adjacent bit too */
            if (f->double_error) {
                int bit2 = (f->bit_position + 1) % 64;
                int word2 = bit2 / 32;
                uint32_t mask2 = (1U << (bit2 % 32));
                if (word2 == 0)
                    data[0].aval ^= mask2;
                else
                    data[1].aval ^= mask2;
            }

            f->consumed = 1;
            f->active   = 0;
            faults_consumed++;

            printf("[ECC_DPI] Fault applied: addr=0x%llx bit=%d %s\n",
                   (unsigned long long)byte_addr, f->bit_position,
                   f->double_error ? "(double)" : "(single)");
            return 1;
        }
    }
    return 0;  /* no fault for this address */
}
