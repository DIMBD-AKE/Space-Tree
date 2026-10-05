#!/usr/bin/env python3
"""Measure an already-running app's CPU delta and RSS without a profiler attached."""
import ctypes
import json
import sys
import time

pid = int(sys.argv[1])
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 10
if pid <= 0 or not 0 < duration <= 60:
    raise SystemExit("Usage: measure-idle.py PID [seconds between 0 and 60]")


class TaskInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in (
        "virtual_size", "resident_size", "total_user", "total_system", "threads_user", "threads_system"
    )] + [(name, ctypes.c_int32) for name in (
        "policy", "faults", "pageins", "cow_faults", "messages_sent", "messages_received",
        "syscalls_mach", "syscalls_unix", "context_switches", "thread_count", "running_threads", "priority"
    )]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
libproc.proc_pidinfo.restype = ctypes.c_int


def read():
    info = TaskInfo()
    if libproc.proc_pidinfo(pid, 4, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise SystemExit("Cannot inspect the process; check PID and permissions.")
    return info


start = time.monotonic()
before = read()
time.sleep(duration)
after = read()
elapsed = time.monotonic() - start
cpu_seconds = (after.total_user + after.total_system - before.total_user - before.total_system) / 1e9
print(json.dumps({
    "pid": pid, "elapsed_seconds": elapsed, "cpu_seconds": cpu_seconds,
    "cpu_percent_of_one_core": cpu_seconds / elapsed * 100,
    "rss_start_bytes": before.resident_size, "rss_end_bytes": after.resident_size,
    "note": "Only an idle measurement if no scan, file changes or user interactions occurred during the interval."
}, indent=2))
