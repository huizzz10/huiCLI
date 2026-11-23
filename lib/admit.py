#!/usr/bin/env python3
# Copyright (C) 2026 hui contributors
# Portions derived from uwuAOSP uni
# Copyright (C) 2026 The uwuAOSP Project
# SPDX-License-Identifier: Apache-2.0
"""Runtime admission for Runa's --parallelism-file.

Runa reads the file every 100ms and only limits *new* commands; running
commands are never interrupted.  This loop lowers the limit under memory
pressure and raises it again when the machine has genuinely spare capacity.

The policy is derived from the uwuAOSP `uni` admission state machine
(https://github.com/uwuAOSP/uwuCLI, Apache-2.0):
  * pressure = low MemAvailable + PSI, active swap, linker-heavy phase,
    or MemAvailable below 512MB;
  * sustained pressure (2s / 6s / 20s depending on severity) lowers the
    limit by 25%, with a 20s cooldown;
  * recovery needs >=15s of healthy memory/PSI with no swap activity and,
    above the initial limit, at least one genuinely idle CPU core.
"""

import argparse
import os
import signal
import sys
import time

PAGE = os.sysconf("SC_PAGE_SIZE")
MIB = 1024 * 1024
LINKER_NAMES = {"ld.lld", "lld", "ld", "ld.gold", "rust-lld"}


def read_meminfo_mb():
    total = avail = 0
    try:
        with open("/proc/meminfo", encoding="ascii", errors="replace") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) >= 2 and fields[0] in ("MemTotal:", "MemAvailable:"):
                    value = int(fields[1]) // 1024
                    if fields[0] == "MemTotal:":
                        total = value
                    else:
                        avail = value
    except (OSError, ValueError):
        pass
    return total, avail


def read_psi_full_avg10():
    try:
        with open("/proc/pressure/memory", encoding="ascii", errors="replace") as handle:
            for line in handle:
                if line.startswith("full "):
                    for field in line.split()[1:]:
                        if field.startswith("avg10="):
                            return float(field[6:])
    except (OSError, ValueError):
        pass
    return 0.0


def read_swap_pages():
    swap_in = swap_out = 0
    try:
        with open("/proc/vmstat", encoding="ascii", errors="replace") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) == 2:
                    if fields[0] == "pswpin":
                        swap_in = int(fields[1])
                    elif fields[0] == "pswpout":
                        swap_out = int(fields[1])
    except (OSError, ValueError):
        pass
    return swap_in, swap_out


def read_cpu_counters():
    try:
        with open("/proc/stat", encoding="ascii", errors="replace") as handle:
            fields = handle.readline().split()
        values = [int(field) for field in fields[1:]]
        return sum(values), (values[3] if len(values) > 3 else 0)
    except (OSError, ValueError):
        return 0, 0


def count_linkers():
    count = 0
    try:
        entries = os.listdir("/proc")
    except OSError:
        return 0
    for name in entries:
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % name, encoding="ascii", errors="replace") as handle:
                if handle.read().strip() in LINKER_NAMES:
                    count += 1
        except OSError:
            continue
    return count


def write_limit(path, jobs):
    temporary = path + ".next"
    with open(temporary, "w", encoding="ascii") as handle:
        handle.write("%d\n" % jobs)
    os.replace(temporary, path)


class Admission:
    def __init__(self, args):
        self.args = args
        self.jobs = args.initial
        self.pressure_since = None
        self.healthy_since = None
        self.next_change = 0.0
        self.previous = None
        self.previous_cpu = None

    def alive(self):
        if self.args.parent <= 0:
            return True
        try:
            os.kill(self.args.parent, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def log(self, message):
        if not self.args.log:
            return
        try:
            with open(self.args.log, "a", encoding="utf-8") as handle:
                handle.write("[hui] %s\n" % message)
        except OSError:
            pass

    def publish(self, reason, total, available, psi, swap_active):
        write_limit(self.args.file, self.jobs)
        self.log("admission %s: -j%d/%d (avail=%dMB psi=%.0f%% swap=%s)"
                 % (reason, self.jobs, self.args.ceiling, available, psi,
                    "active" if swap_active else "idle"))

    def observe(self, now, total, available, psi, swap_active):
        reserve = max(3072, total // 8)
        linkers = 0
        if available < 2 * reserve and psi >= 35:
            linkers = count_linkers()
        linker_heavy = (linkers >= max(4, (self.args.initial + 2) // 3)
                        and available < 2 * reserve and psi >= 35)
        pressured = ((available < reserve and psi >= 20)
                     or (psi >= 20 and swap_active)
                     or (available < total // 3 and psi >= 45)
                     or linker_heavy
                     or available < 512)

        if pressured:
            self.healthy_since = None
            if self.pressure_since is None:
                self.pressure_since = now
            duration = 20.0
            if psi >= 45 or linker_heavy:
                duration = 6.0
            if available < 512:
                duration = 2.0
            if (now - self.pressure_since >= duration and now >= self.next_change
                    and self.jobs > 1):
                previous = self.jobs
                self.jobs = max(1, self.jobs - self.jobs // 4)
                if self.jobs == previous:
                    self.jobs = max(1, self.jobs - 1)
                self.next_change = now + 20.0
                self.publish("pressure", total, available, psi, swap_active)
            return

        self.pressure_since = None
        if now < self.next_change or self.jobs >= self.args.ceiling:
            return
        if available < max(6144, total // 5) or psi >= 10 or swap_active:
            self.healthy_since = None
            return
        if self.healthy_since is None:
            self.healthy_since = now
        if now - self.healthy_since < 15.0:
            return

        cpu_total, cpu_idle = read_cpu_counters()
        idle_ok = True
        if self.jobs >= self.args.initial and self.previous_cpu is not None:
            previous_total, previous_idle = self.previous_cpu
            delta_total = cpu_total - previous_total
            delta_idle = cpu_idle - previous_idle
            cpus = os.cpu_count() or 1
            idle_ok = delta_total > 0 and delta_idle * cpus >= delta_total
        if not idle_ok:
            return

        step = max(1, self.args.initial // 6)
        self.jobs = min(self.args.ceiling, self.jobs + step)
        self.next_change = now + 15.0
        self.healthy_since = now
        self.publish("recovery", total, available, psi, swap_active)

    def run(self):
        write_limit(self.args.file, self.jobs)
        while True:
            time.sleep(self.args.tick)
            if not self.alive():
                return 0
            total, available = read_meminfo_mb()
            psi = read_psi_full_avg10()
            swap_in, swap_out = read_swap_pages()
            now = time.monotonic()
            swap_active = False
            if self.previous is not None:
                previous_now, previous_in, previous_out = self.previous
                elapsed = now - previous_now
                if elapsed > 0 and swap_in >= previous_in and swap_out >= previous_out:
                    rate_in = (swap_in - previous_in) * PAGE / elapsed
                    rate_out = (swap_out - previous_out) * PAGE / elapsed
                    swap_active = (rate_in >= 4 * MIB or rate_out >= 16 * MIB)
            self.previous = (now, swap_in, swap_out)
            self.observe(now, total, available, psi, swap_active)
            self.previous_cpu = read_cpu_counters()
            if self.args.stat:
                try:
                    with open(self.args.stat, "w", encoding="ascii") as handle:
                        handle.write("%d %d\n" % (self.jobs, int(psi)))
                except OSError:
                    pass


def parse_args():
    parser = argparse.ArgumentParser(description="hui runtime admission")
    parser.add_argument("--file", required=True)
    parser.add_argument("--initial", type=int, required=True)
    parser.add_argument("--ceiling", type=int, required=True)
    parser.add_argument("--parent", type=int, default=0)
    parser.add_argument("--stat", default="")
    parser.add_argument("--log", default="")
    parser.add_argument("--tick", type=float, default=2.0)
    args = parser.parse_args()
    if args.initial < 1 or args.ceiling < args.initial:
        parser.error("require 1 <= initial <= ceiling")
    if args.tick < 0.2:
        parser.error("tick must be >= 0.2")
    return args


def main():
    args = parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    return Admission(args).run()


if __name__ == "__main__":
    sys.exit(main())
