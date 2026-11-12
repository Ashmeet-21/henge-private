#!/usr/bin/env python3
"""Exercise the production Mac-app address reservations with real Mach mappings.

Only the reservation code is compiled: this test never attaches a debugger or
requests executable memory. Large mappings reserve addresses without allocating
physical RAM. iOS's extended-address range is translated into a host-allocated
window because macOS cannot guarantee that fixed iOS address range is available. Allocation and
deallocation still use the real Mach API. Each case runs in its own process.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', metavar='UDID', help='run inside a booted iOS Simulator')
args = parser.parse_args()
sdk = 'iphonesimulator' if args.simulator else 'macosx'
sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
target = 'arm64-apple-ios17.0-simulator' if args.simulator else 'arm64-apple-macosx14.0'

def execute(command):
    if args.simulator:
        command = ['xcrun', 'simctl', 'spawn', args.simulator] + command
    subprocess.run(command, check=True, timeout=30)

root = Path(__file__).resolve().parents[1]
source = (root / 'ios/Henge/Native/henge-ios-jit.c').read_text()
start = source.index('#define HENGE_HIGH_BASE ')
end = source.index('static HengeDualMapping henge_prewarmed;', start)
reservation_code = source[start:end]
harness = r'''
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static vm_address_t test_window;
static int test_fail_release;
static kern_return_t test_open_window(void) {
    kern_return_t result = vm_allocate(mach_task_self(), &test_window, 64ull << 30, VM_FLAGS_ANYWHERE);
    if (result == KERN_SUCCESS) result = vm_deallocate(mach_task_self(), test_window, 64ull << 30);
    return result;
}
static vm_address_t test_actual(vm_address_t logical) {
    if (logical >= 0x7000000000ull && logical < 0x8000000000ull)
        return test_window + (logical - 0x7000000000ull);
    return logical;
}
static kern_return_t test_allocate(vm_map_t task, vm_address_t *at, vm_size_t size, int flags) {
    vm_address_t logical = *at, real = test_actual(logical);
    kern_return_t result = vm_allocate(task, &real, size, flags);
    if (result == KERN_SUCCESS) *at = logical >= 0x7000000000ull && logical < 0x8000000000ull ? logical : real;
    return result;
}
static kern_return_t test_deallocate(vm_map_t task, vm_address_t at, vm_size_t size) {
    if (test_fail_release && at == 0x7000000000ull) return KERN_FAILURE;
    return vm_deallocate(task, test_actual(at), size);
}
static kern_return_t test_protect(vm_map_t task, vm_address_t at, vm_size_t size, boolean_t maximum, vm_prot_t prot) {
    return vm_protect(task, test_actual(at), size, maximum, prot);
}
#define vm_allocate test_allocate
#define vm_deallocate test_deallocate
#define vm_protect test_protect
#define HENGE_EXPORT
#define HENGE_LOG(...) do { fprintf(stderr, __VA_ARGS__); fputc(10, stderr); } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
'''
test = r'''
int main(int argc, char **argv) {
    REQUIRE(argc == 2);
    REQUIRE(test_open_window() == KERN_SUCCESS);
    henge_ios_hold_high();
    for (int i = 0; i < 3; i++) REQUIRE(g_high_hold[i] == g_high_parts[i].at);
    if (!strcmp(argv[1], "retry")) {
        test_fail_release = 1;
        henge_ios_jit_prepare_vm_memory();
        REQUIRE(g_high_hold[0] == g_high_parts[0].at);
        REQUIRE(g_high_hold[1] == 0 && g_high_hold[2] == 0);
        test_fail_release = 0;
        henge_ios_jit_prepare_vm_memory();
        for (int i = 0; i < 3; i++) REQUIRE(g_high_hold[i] == 0);
        puts("PASS: a failed release stays tracked and can be retried");
        return 0;
    }
    if (!strcmp(argv[1], "claimed")) {
        void *base[3]; size_t bytes[3];
        REQUIRE(henge_ios_take_high_room(base, bytes) == 3);
        henge_ios_jit_prepare_vm_memory();
        vm_address_t p = (vm_address_t)(uintptr_t)base[0];
        REQUIRE(vm_allocate(mach_task_self(), &p, 16384, VM_FLAGS_FIXED) == KERN_NO_SPACE);
        REQUIRE(henge_ios_take_high_room(base, bytes) == 0);
        puts("PASS: VM preparation preserves rooms already owned by a Mac app");
        return 0;
    }
    /* The reported iPhone had only the 4 GiB gap between these holds left.
       Runtime metadata consumes part of that gap after the Swift RAM probe. */
    vm_address_t metadata = HENGE_JIT_VIEW_AT;
    REQUIRE(vm_allocate(mach_task_self(), &metadata, 768ull << 20, VM_FLAGS_FIXED) == KERN_SUCCESS);
    *(volatile unsigned char *)test_actual(metadata) = 0x5a;
    vm_address_t ram = metadata + (768ull << 20);
    REQUIRE(vm_allocate(mach_task_self(), &ram, 3584ull << 20, VM_FLAGS_FIXED) == KERN_NO_SPACE);
    henge_ios_jit_prepare_vm_memory();
    REQUIRE(*(volatile unsigned char *)test_actual(metadata) == 0x5a);
    for (int i = 0; i < 3; i++) REQUIRE(g_high_hold[i] == 0);
    ram = metadata + (768ull << 20);
    REQUIRE(vm_allocate(mach_task_self(), &ram, 4096ull << 20, VM_FLAGS_FIXED) == KERN_SUCCESS);
    *(volatile unsigned char *)test_actual(ram) = 0x34;
    henge_ios_jit_prepare_vm_memory();
    REQUIRE(*(volatile unsigned char *)test_actual(ram) == 0x34 && *(volatile unsigned char *)test_actual(metadata) == 0x5a);
    REQUIRE(vm_deallocate(mach_task_self(), ram, 4096ull << 20) == KERN_SUCCESS);
    REQUIRE(vm_deallocate(mach_task_self(), metadata, 768ull << 20) == KERN_SUCCESS);
    puts("PASS: held-room allocation failure reproduced; release permits 4096 MiB RAM; live mappings survive repeat preparation");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='henge-high-room-', dir='/private/tmp') as tmp:
    path = Path(tmp)
    (path / 'test.c').write_text(harness + reservation_code + test)
    subprocess.run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdk_path,
                    '-Wall', '-Wextra', '-Werror', str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    for case in ['vm', 'claimed', 'retry']:
        execute([str(path / 'test'), case])

# Exercise the app's real Swift RAM sizing path with a controlled address probe.
machines = (root / 'ios/Henge/Machines.swift').read_text()
start = machines.index('enum GuestMemory {')
end = machines.index('/// machine.json', start)
swift = r'''import Foundation
var held = true
var preparations = 0
func henge_ios_jit_prepare_vm_memory() { held = false; preparations += 1 }
func henge_largest_mapping_mb() -> UInt64 {
    precondition(!held, "unused reservations must be released before the RAM probe")
    return 16896
}
struct VirtualMac { var directory: URL; var ramMB: Int }
enum Device { static let hasLittleMemory = false; static let suggestedRAMGB = 3 } // fork: 6 GB cap reads Device
enum HengeLog { static func log(_ category: String, _ message: String) {} }
''' + machines[start:end] + r'''
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder); unsetenv("HV_RAM_FILE") }
precondition(GuestMemory.prepare(VirtualMac(directory: folder, ramMB: 4096)) == 4096)
held = true
precondition(GuestMemory.prepare(VirtualMac(directory: folder, ramMB: 2048)) == 2048)
precondition(preparations == 2)
precondition(String(cString: getenv("HV_RAM_FILE")) == folder.appendingPathComponent("ram.tmp").path)
print("PASS: app releases unused rooms before sizing RAM; requested RAM and file path are preserved")
'''
with tempfile.TemporaryDirectory(prefix='henge-guest-memory-', dir='/private/tmp') as tmp:
    path = Path(tmp)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', '--sdk', sdk, 'swiftc', '-swift-version', '5', '-target', target, '-sdk', sdk_path,
                    '-module-cache-path', str(root / 'build/swift-module-cache'), str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    execute([str(path / 'test')])
print('JIT high address reservations: 4 cases, 0 failures')

