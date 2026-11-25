#!/usr/bin/env python3
# Copyright (C) 2026 hui contributors
# Portions derived from uwuAOSP uni
# Copyright (C) 2026 The uwuAOSP Project
# SPDX-License-Identifier: Apache-2.0
"""Runtime admission for the executor's --parallelism-file.

The executor only limits *new* commands; running commands are never
interrupted.  Two policies are available:

``legacy``
    The uwuAOSP ``uni`` style step controller: sustained pressure lowers the
    limit by 25% (20s cooldown), recovery needs 15s of healthy memory/PSI and
    only moves one small step at a time.

``pid`` (default)
    Feed-forward + incremental PI(D) on a smoothed pressure score:

    * feed-forward  u_ff = (MemAvailable + f*SwapFree - reserve) / per_job
    * measurement   p   = 0.55*PSI + 0.25*swapout-rate + 0.20*avail-deficit
    * error         e   = setpoint - EMA(p)
    * output        u   = clamp(u_ff + Kp*e + I + Kd*d, floor, ceiling)
      with conditional-integration anti-windup, integer dead-band and a
      slew-rate limit (up is slower than down).
    * emergency override cuts immediately when PSI/swap-out/avail are red.

Swap *occupancy* is deliberately not a pressure signal: it is a ratchet that
stays high long after the pressure is gone.  Free swap is counted (partially)
in the feed-forward instead.
"""

import argparse
import math
import os
import signal
import sys
import time

PAGE = os.sysconf("SC_PAGE_SIZE")
MIB = 1024 * 1024
LINKER_NAMES = {"ld.lld", "lld", "ld", "ld.gold", "rust-lld"}


def cpu_affinity_count():
    try:
        return len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return os.cpu_count() or 1


def auto_scale_enabled():
    value = os.environ.get("HUI_CPU_SCALE", "auto").strip().lower()
    return value not in ("0", "off", "false", "no", "manual")


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


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


def read_psi_cpu_avg10():
    try:
        with open("/proc/pressure/cpu", encoding="ascii", errors="replace") as handle:
            for line in handle:
                if line.startswith("some "):
                    for field in line.split()[1:]:
                        if field.startswith("avg10="):
                            return float(field[6:])
    except (OSError, ValueError):
        pass
    return 0.0


def read_swap_mb():
    total = free = 0
    try:
        with open("/proc/meminfo", encoding="ascii", errors="replace") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) >= 2:
                    if fields[0] == "SwapTotal:":
                        total = int(fields[1]) // 1024
                    elif fields[0] == "SwapFree:":
                        free = int(fields[1]) // 1024
    except (OSError, ValueError):
        pass
    return total, free


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


def write_stat(path, jobs, psi):
    if not path:
        return
    try:
        with open(path, "w", encoding="ascii") as handle:
            handle.write("%d %d\n" % (jobs, int(psi)))
    except OSError:
        pass


class ControllerBase:
    def __init__(self, args):
        self.args = args
        self.jobs = float(args.initial)
        self.last_written = args.initial
        self.previous = None  # (monotonic, pswpin, pswpout)
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
        path = self.args.ctrl_log or self.args.log
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
        except OSError:
            pass


class Admission(ControllerBase):
    """legacy: uwuAOSP uni style step controller."""

    def __init__(self, args):
        super().__init__(args)
        self.pressure_since = None
        self.healthy_since = None
        self.next_change = 0.0

    def publish(self, reason, total, available, psi, swap_active):
        write_limit(self.args.file, self.last_written)
        self.log("admission %s: -j%d/%d (avail=%dMB psi=%.0f%% swap=%s)"
                 % (reason, self.last_written, self.args.ceiling, available, psi,
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
                    and self.last_written > 1):
                previous = self.last_written
                self.last_written = max(1, previous - previous // 4)
                if self.last_written == previous:
                    self.last_written = max(1, previous - 1)
                self.next_change = now + 20.0
                self.publish("pressure", total, available, psi, swap_active)
            return

        self.pressure_since = None
        if now < self.next_change or self.last_written >= self.args.ceiling:
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
        if self.last_written >= self.args.initial and self.previous_cpu is not None:
            previous_total, previous_idle = self.previous_cpu
            delta_total = cpu_total - previous_total
            delta_idle = cpu_idle - previous_idle
            cpus = os.cpu_count() or 1
            idle_ok = delta_total > 0 and delta_idle * cpus >= delta_total
        if not idle_ok:
            return

        step = max(1, self.args.initial // 6)
        self.last_written = min(self.args.ceiling, self.last_written + step)
        self.next_change = now + 15.0
        self.healthy_since = now
        self.publish("recovery", total, available, psi, swap_active)

    def run(self):
        write_limit(self.args.file, self.last_written)
        self.log("admission start policy=legacy initial=%d ceiling=%d"
                 % (self.args.initial, self.args.ceiling))
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
            write_stat(self.args.stat, self.last_written, psi)


class PidAdmission(ControllerBase):
    """feed-forward + incremental PI(D) admission controller."""

    def __init__(self, args):
        super().__init__(args)
        self.ceiling = args.ceiling
        self.floor = max(1, min(args.floor, args.ceiling))
        self.limit = float(max(self.floor, min(args.initial, self.ceiling)))
        self.last_written = int(round(self.limit))
        self.integral = 0.0
        self.p_hat = None
        self.previous_p = None
        self.last_tick = None

        self.kp = env_float("HUI_CTRL_KP", 8.0)
        self.ki = env_float("HUI_CTRL_KI", 0.4)
        self.kd = env_float("HUI_CTRL_KD", 0.0)
        self.setpoint = env_float("HUI_CTRL_SETPOINT", 0.30)
        self.tau = max(0.5, env_float("HUI_CTRL_TAU", 5.0))
        # 速率按核数缩放：32 线程维持 1/2 路每秒，128 线程到 4/8，
        # 小机器不低于 1/2。显式 HUI_CTRL_UP/DOWN 永远优先；
        # HUI_CPU_SCALE=off 关掉自动缩放（回到固定 1/2）。
        self.cpus = cpu_affinity_count()
        self.auto_scale = auto_scale_enabled()
        up_env = os.environ.get("HUI_CTRL_UP", "").strip()
        down_env = os.environ.get("HUI_CTRL_DOWN", "").strip()
        if up_env:
            self.up_rate = max(0.05, env_float("HUI_CTRL_UP", 1.0))
        elif self.auto_scale:
            self.up_rate = max(1.0, self.cpus / 32.0)
        else:
            self.up_rate = 1.0
        if down_env:
            self.down_rate = max(0.05, env_float("HUI_CTRL_DOWN", 2.0))
        elif self.auto_scale:
            self.down_rate = max(2.0, self.cpus / 16.0)
        else:
            self.down_rate = 2.0
        self.i_limit = max(0.0, env_float("HUI_CTRL_I_LIMIT", 6.0))
        self.swap_frac = min(1.0, max(0.0, env_float("HUI_CTRL_SWAP_HEADROOM", 0.5)))
        self.per_job = max(0.1, env_float("HUI_MEM_PER_JOB", 1.2))
        self.reserve = max(0.0, env_float("HUI_MEM_RESERVE_MB", 2048.0))
        self.psi_span = max(1.0, env_float("HUI_CTRL_PSI_SPAN", 25.0))
        self.swap_span = max(1.0, env_float("HUI_CTRL_SWAPOUT_SPAN_MB", 16.0)) * MIB
        self.emergency_psi = env_float("HUI_CTRL_EMERGENCY_PSI", 40.0)
        self.emergency_swap = env_float("HUI_CTRL_EMERGENCY_SWAP_MB", 32.0) * MIB
        self.emergency_avail = max(256.0, env_float("HUI_CTRL_EMERGENCY_AVAIL_MB", 1536.0))
        self.emergency_confirm = max(1, int(env_float("HUI_CTRL_EMERGENCY_CONFIRM", 3)))
        self.emergency_streak = 0
        self.debug = os.environ.get("HUI_CTRL_DEBUG", "0") not in ("0", "", "off", "false")
        # 稳妥版：CPU 饱和时不升档；前馈用 EMA；急停后冷却；不许逆压升档。
        self.cpu_freeze = max(0.0, min(100.0, env_float("HUI_CTRL_CPU_FREEZE", 70.0)))
        self.cpu_down = max(self.cpu_freeze,
                            min(100.0, env_float("HUI_CTRL_CPU_DOWN", 85.0)))
        cpu_min = max(0.0, min(1.0, env_float("HUI_CTRL_CPU_MIN_FRACTION", 0.5)))
        self.cpu_floor = min(self.ceiling, max(self.floor, int(round(self.ceiling * cpu_min))))
        self.ff_tau = max(1.0, env_float("HUI_CTRL_FF_TAU", 15.0))
        self.raise_eps = env_float("HUI_CTRL_RAISE_EPS", 0.03)
        self.hold = max(0.0, env_float("HUI_CTRL_HOLD", 15.0))
        self.headroom_slack = max(1.0, env_float("HUI_CTRL_HEADROOM_SLACK", 1.1))
        self.ff_hat = None
        self.hold_until = 0.0

    def measure(self, total, available, psi, swap_out_rate):
        p_psi = min(1.5, psi / self.psi_span)
        p_swap = min(1.0, swap_out_rate / self.swap_span)
        low = max(6144.0, total * 0.25)
        hard = min(self.emergency_avail, low - 1.0)
        if available >= low:
            p_mem = 0.0
        else:
            p_mem = min(1.0, (low - available) / (low - hard))
        p = 0.55 * p_psi + 0.25 * p_swap + 0.20 * p_mem
        return max(0.0, min(1.5, p))

    def headroom(self, available, swap_free):
        credit = self.swap_frac * swap_free
        if credit > available:
            credit = float(available)
        return available + credit

    def feedforward(self, available, swap_free, dt):
        headroom = self.headroom(available, swap_free)
        if self.ff_hat is None:
            self.ff_hat = headroom
        else:
            alpha = 1.0 - math.exp(-dt / self.ff_tau)
            self.ff_hat += alpha * (headroom - self.ff_hat)
        value = (self.ff_hat - self.reserve) / (self.per_job * 1024.0)
        return max(1.0, min(float(self.ceiling), value))

    def apply(self, u, emergency, dt):
        u = max(float(self.floor), min(float(self.ceiling), u))
        step_up = self.up_rate * dt
        step_down = (self.down_rate * 2.0 if emergency else self.down_rate) * dt
        delta = max(-step_down, min(step_up, u - self.limit))
        self.limit = max(1.0, min(float(self.ceiling), self.limit + delta))

    def sample(self):
        total, available = read_meminfo_mb()
        swap_total, swap_free = read_swap_mb()
        psi = read_psi_full_avg10()
        cpu_psi = read_psi_cpu_avg10()
        swap_in, swap_out = read_swap_pages()
        return total, available, swap_total, swap_free, psi, cpu_psi, swap_in, swap_out

    def step(self, sample=None, now=None):
        if now is None:
            now = time.monotonic()
        dt = 1.0 if self.last_tick is None else max(0.2, min(5.0, now - self.last_tick))
        self.last_tick = now

        if sample is None:
            sample = self.sample()
        total, available, swap_total, swap_free, psi, cpu_psi, swap_in, swap_out = sample

        rate_out = 0.0
        if self.previous is not None:
            previous_now, previous_in, previous_out = self.previous
            elapsed = now - previous_now
            if elapsed > 0 and swap_out >= previous_out:
                rate_out = (swap_out - previous_out) * PAGE / elapsed
        self.previous = (now, swap_in, swap_out)

        p = self.measure(total, available, psi, rate_out)
        if self.p_hat is None:
            self.p_hat = p
        else:
            alpha = 1.0 - math.exp(-dt / self.tau)
            self.p_hat += alpha * (p - self.p_hat)

        u_ff = self.feedforward(available, swap_free, dt)
        error = self.setpoint - self.p_hat

        derivative = 0.0
        if self.previous_p is not None:
            derivative = -(self.p_hat - self.previous_p) / dt
        self.previous_p = self.p_hat

        # 硬急停（内存见底 / PSI 爆表）立即生效；
        # 换出速率是秒级尖峰（实测 0→227→0），要求连续多个采样确认再砍。
        hard_emergency = (psi >= self.emergency_psi
                          or available < self.emergency_avail)
        soft_emergency = rate_out >= self.emergency_swap
        if hard_emergency or soft_emergency:
            self.emergency_streak += 1
        else:
            self.emergency_streak = 0
        emergency = hard_emergency or (soft_emergency
                                       and self.emergency_streak >= self.emergency_confirm)

        # 稳妥版升档锁：CPU 饱和、急停冷却期、或换出尖峰确认期内，不往“加线程”方向积分。
        freeze_up = (cpu_psi >= self.cpu_freeze
                     or now < self.hold_until
                     or self.emergency_streak > 0)
        integral_candidate = self.integral + self.ki * error * dt
        if self.i_limit > 0:
            integral_candidate = max(-self.i_limit, min(self.i_limit, integral_candidate))
        raw = u_ff + self.kp * error + integral_candidate + self.kd * derivative
        saturated = ((raw > self.ceiling and error > 0)
                     or (raw < self.floor and error < 0))
        if freeze_up and error > 0:
            integral_candidate = self.integral
        if not saturated:
            self.integral = integral_candidate

        u = u_ff + self.kp * error + self.integral + self.kd * derivative
        hard_jobs = (self.headroom(available, swap_free) - self.reserve) / (self.per_job * 1024.0)
        u = min(u, max(float(self.floor), hard_jobs * self.headroom_slack))
        if emergency:
            self.hold_until = now + self.hold
            u = min(u, max(float(self.floor), self.limit * 0.75))
            self.integral *= 0.5
        elif cpu_psi >= self.cpu_down:
            # CPU 已明显排队：往半个机器线程数附近收，不回落到内存下限。
            # 注意不能再升：急停可能已经把 limit 砍到 cpu_floor 以下。
            u = min(u, max(float(self.cpu_floor), self.limit - 1.0), self.limit)
        elif freeze_up or error <= self.raise_eps:
            # 不许逆压/逆 CPU 升档：只允许持平或下降。
            u = min(u, self.limit)

        self.apply(u, emergency, dt)

        new_jobs = max(self.floor, min(self.ceiling, int(math.floor(self.limit + 0.5))))
        if emergency:
            reason = "emergency"
        elif new_jobs > self.last_written:
            reason = "raise"
        elif new_jobs < self.last_written:
            reason = "lower"
        else:
            reason = "hold"
        if new_jobs != self.last_written or self.debug:
            self.log("ctrl %-9s -j%d -> -j%d  p=%.2f p*=%.2f u_ff=%.1f "
                     "e=%+.2f I=%+.1f d=%+.2f avail=%dMB swapfree=%dMB "
                     "psi=%.1f%% cpu=%.0f%% out=%.1fMB/s estk=%d"
                     % (reason, self.last_written, new_jobs, self.p_hat,
                        self.setpoint, u_ff, error, self.integral, derivative,
                        available, swap_free, psi, cpu_psi, rate_out / MIB,
                        self.emergency_streak))
            if new_jobs != self.last_written:
                write_limit(self.args.file, new_jobs)
                self.last_written = new_jobs

        write_stat(self.args.stat, self.last_written, psi)
        return reason, new_jobs

    def run(self):
        write_limit(self.args.file, self.last_written)
        self.log("ctrl start policy=pid initial=%d floor=%d ceiling=%d "
                 "kp=%.2f ki=%.2f kd=%.2f setpoint=%.2f tau=%.1f "
                 "up=%.1f down=%.1f swap_frac=%.2f per_job=%.2f "
                 "ff_tau=%.0f cpu_freeze=%.0f cpu_down=%.0f cpu_floor=%d hold=%.0f slack=%.2f emerg_confirm=%d cpus=%d scale=%s"
                 % (self.last_written, self.floor, self.ceiling, self.kp, self.ki,
                    self.kd, self.setpoint, self.tau, self.up_rate, self.down_rate,
                    self.swap_frac, self.per_job, self.ff_tau, self.cpu_freeze,
                    self.cpu_down, self.cpu_floor, self.hold, self.headroom_slack,
                    self.emergency_confirm, self.cpus,
                    "auto" if self.auto_scale else "off"))
        while True:
            time.sleep(self.args.tick)
            if not self.alive():
                return 0
            self.step()


def parse_args():
    parser = argparse.ArgumentParser(description="hui runtime admission")
    parser.add_argument("--file", required=True)
    parser.add_argument("--initial", type=int, required=True)
    parser.add_argument("--ceiling", type=int, required=True)
    parser.add_argument("--floor", type=int, default=1)
    parser.add_argument("--policy", default=os.environ.get("HUI_ADMIT_POLICY", "pid"))
    parser.add_argument("--parent", type=int, default=0)
    parser.add_argument("--stat", default="")
    parser.add_argument("--log", default="")
    parser.add_argument("--ctrl-log", default="")
    parser.add_argument("--tick", type=float,
                        default=env_float("HUI_ADMIT_TICK", 1.0))
    args = parser.parse_args()
    args.policy = str(args.policy).lower()
    if args.policy not in ("legacy", "pid"):
        parser.error("policy must be legacy or pid")
    if args.initial < 1 or args.ceiling < args.initial:
        parser.error("require 1 <= initial <= ceiling")
    if args.floor < 1:
        args.floor = 1
    if args.floor > args.initial:
        args.floor = args.initial
    if args.tick < 0.2:
        parser.error("tick must be >= 0.2")
    return args


def main():
    args = parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    if args.policy == "pid":
        return PidAdmission(args).run()
    return Admission(args).run()


if __name__ == "__main__":
    sys.exit(main())
