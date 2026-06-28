# Two-Level Cache Controller (L1 + L2) — Verilog Behavioral Model

A Verilog model of a two-level cache hierarchy, built for a Computer Architecture course assignment. It simulates a processor's read/write requests flowing through an L1 cache, an L2 cache, and main memory — with realistic hit/miss behavior, multi-cycle access latencies, LRU replacement, and block promotion/eviction between levels.

## Overview

The design models a classic memory hierarchy:

```
Processor <--> L1 Cache <--> L2 Cache <--> Main Memory
```

| Level | Organization | Size | Latency |
|---|---|---|---|
| L1 | Direct-mapped | 64 lines × 4 bytes | 1 cycle |
| L2 | 4-way set-associative, LRU replacement | 128 sets × 4 ways × 4 bytes | 3 cycles |
| Main Memory | — | 16384 blocks × 4 bytes (64 KB) | 10 cycles |

On every request, the controller:
1. Checks L1 for a hit.
2. On an L1 miss, waits out the L2 access latency, then checks all 4 ways of the relevant L2 set.
3. On an L2 hit, updates LRU state for the set and promotes the block into L1 — evicting and writing back the current L1 occupant to L2 or main memory if needed.
4. On an L2 miss, waits out the main memory latency, then fetches the block from main memory, installs it into L2 (evicting the LRU way if the set is full, with writeback to main memory if that victim was valid), and promotes it into L1 with the same eviction/writeback handling.

Writes follow the same hit-search cascade (L1 → L2 → main memory) and update data in place at whichever level the block is found.

The controller exposes `hit1` / `hit2` signals (L1 and L2 hit indicators) and a `Wait` signal that tells the processor when the controller is still servicing a request, so back-to-back accesses are handled correctly.

## What this is (and isn't)

This is a **functional/behavioral simulation model**, written to demonstrate correct cache hierarchy behavior — hit/miss timing, LRU replacement, and eviction/writeback logic — against a testbench. It is **not synthesizable RTL**. A few design choices make that explicit:

- Sub-modules (`L1_CACHE_MEMORY`, `L2_CACHE_MEMORY`, `MAIN_MEMORY`) are accessed via hierarchical (dot-notation) references rather than ports, which is valid in simulation but has no synthesis equivalent.
- Multi-cycle access latencies are modeled with simple delay counters rather than a true register-level FSM.
- Blocking assignments (`=`) are used throughout inside the clocked block, relying on same-cycle read-after-write ordering that isn't representative of real hardware timing.

These were reasonable simplifications for the scope of the assignment (correctness of cache behavior over a testbench, not a tapeout-ready design), but would need to be addressed — proper module ports, a registered FSM, and non-blocking assignments for actual state — before this could be synthesized to real hardware.

## Repository Contents

- `cache_controller.v` — top-level cache controller module
- (add: `l1_cache_memory.v`, `l2_cache_memory.v`, `main_memory.v`, testbench files, etc.)

## Parameters

Key configurable parameters (set via Verilog `parameter`s at the top of the module):

- Address width, block offset width, byte size
- L1: number of lines, tag/index widths
- L2: number of ways, number of sets, tag/index widths
- Main memory size
- Access latencies for L1, L2, and main memory

## Author

Built as a Computer Architecture course assignment.
