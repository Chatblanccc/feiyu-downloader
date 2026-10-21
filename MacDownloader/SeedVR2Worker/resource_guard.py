#!/usr/bin/env python3
"""Independent Seed worker OS-memory guardian. Never imports torch.

Inherits the Swift-owned process group. stdout is only Feather NDJSON heartbeat;
only the explicitly identified parent may be signalled, never a process group.
"""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import signal
import sys
import time
import traceback

import psutil

GIB = 1024**3
STOP = False


def request_stop(_signal, _frame):
    global STOP
    STOP = True


def atomic_json(path, value):
    temporary = path.with_name(path.name+'.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False)+'\n', encoding='utf-8')
    temporary.replace(path)


def owner_matches(process, start_time):
    try:
        return (process.is_running() and process.status() != psutil.STATUS_ZOMBIE
                and process.create_time() == start_time and os.getppid() == process.pid)
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


def heartbeat(state_path, summary):
    try:
        state = json.loads(state_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return
    total = max(1, int(state.get('framesTotal', 1)))
    written = max(0, int(state.get('written', 0)))
    elapsed = max(.001, time.monotonic()-float(state['started']))
    speed = written/elapsed
    detail = str(state.get('phase', '准备本地模型'))[:100]
    chunk = int(state.get('chunk', 0))
    if chunk:
        detail = f'第 {chunk} 块 · '+detail
    detail += f' · 已导出 {written}/{total} 帧'
    remaining = max(0, total-written)/speed if speed else None
    if written > 0:
        detail += f' · {speed:.2f} 帧/秒'
        if remaining is not None and remaining > 0:
            minutes = math.ceil(remaining/60)
            estimate = (f'{math.ceil(remaining)} 秒' if remaining < 60 else
                        f'{minutes} 分钟' if minutes < 60 else f'{minutes//60} 小时 {minutes%60} 分钟')
            detail += ' · 预计剩余约 '+estimate
    if summary['guardReason']:
        detail = '正在停止：'+summary['guardReason']
    message = {'type': 'progress', 'progress': .95 if state.get('stage') == 'encoding' else .01+.92*min(.999, written/total),
               'stage': 'stopping' if summary['guardReason'] else state.get('stage') or ('enhancing' if chunk else 'preparing'), 'message': detail,
               'framesProcessed': written, 'framesPrepared': int(state.get('read', 0)), 'framesTotal': total,
               'regionsRepaired': 0, 'framesPerSecond': round(speed, 4),
               'estimatedRemainingSeconds': round(remaining) if remaining is not None else None,
               'performance': state.get('performance', 'quality'), 'device': 'mps',
               'monitorPID': os.getpid(), 'monitorSampleCount': summary['sampleCount'],
               'monitorElapsedSeconds': round(time.monotonic()-summary['startedMonotonic'], 3)}
    print(json.dumps(message, ensure_ascii=False, allow_nan=False), flush=True)


def run(args):
    parent = psutil.Process(args.parent_pid)
    summary = {'independentProcess': True, 'monitorPID': os.getpid(), 'guardedPID': args.parent_pid,
               'guardedStartTime': args.parent_start_time, 'targetSampleIntervalSeconds': args.interval,
               'sampleCount': 0, 'maxObservedSampleGapSeconds': 0.0,
               'peakProcessTreeRSSBytes': 0, 'peakAdditionalSwapBytes': 0,
               'minimumSystemAvailableBytes': psutil.virtual_memory().available,
               'mpsPeakTensorBytes': None, 'mpsPeakDriverBytes': None,
               'mpsStatisticsAvailable': False,
               'mpsStatisticsNote': 'Not queried: MPS allocator statistics must not block resource protection.',
               'startedMonotonic': time.monotonic(), 'lastSampleElapsedSeconds': 0.0,
               'guardReason': None, 'exitReason': None, 'signalsSent': [],
               'limits': {'processTreeRSSBytes': args.memory_budget, 'minimumAvailableBytes': args.min_available,
                          'maximumAdditionalSwapBytes': args.max_swap_growth, 'consecutiveSamples': args.consecutive}}
    baseline_swap = psutil.swap_memory().used
    bad = [0, 0, 0]
    last = None
    termination_deadline = None
    def signal_owner(reason):
        summary['guardReason'] = reason
        # Persistence failure (e.g. ENOSPC) must not prevent safe termination.
        with contextlib.suppress(OSError):
            atomic_json(args.metrics, summary)
        # If native code never returns, the parent may have to be KILLed and
        # cannot emit its own error. The guardian is still the sole writer here.
        with contextlib.suppress(BrokenPipeError, OSError):
            print(json.dumps({'type': 'error', 'message': reason}, ensure_ascii=False), flush=True)
        # Revalidate identity immediately before signalling. No killpg/setsid.
        if owner_matches(parent, args.parent_start_time):
            parent.send_signal(signal.SIGTERM)
            summary['signalsSent'].append('SIGTERM')
    def finish_failed_monitor():
        deadline = time.monotonic()+args.term_grace
        while not STOP and not args.stop_file.exists() and time.monotonic() < deadline:
            if not owner_matches(parent, args.parent_start_time):
                return
            time.sleep(.1)
        if not STOP and not args.stop_file.exists() and owner_matches(parent, args.parent_start_time):
            parent.send_signal(signal.SIGKILL)
            summary['signalsSent'].append('SIGKILL')
    try:
        if not owner_matches(parent, args.parent_start_time):
            summary['exitReason'] = 'parent_identity_mismatch'
            return 0
        while not STOP and not args.stop_file.exists():
            if not owner_matches(parent, args.parent_start_time):
                summary['exitReason'] = 'parent_exited'
                return 0
            now = time.monotonic()
            processes = [parent]
            with contextlib.suppress(psutil.NoSuchProcess):
                processes += parent.children(recursive=True)
            rss = 0
            for process in processes:
                try:
                    if process.is_running() and process.status() != psutil.STATUS_ZOMBIE:
                        rss += process.memory_info().rss
                except psutil.NoSuchProcess:
                    continue
            available = psutil.virtual_memory().available
            swap = max(0, psutil.swap_memory().used-baseline_swap)
            summary['sampleCount'] += 1
            if last is not None:
                summary['maxObservedSampleGapSeconds'] = max(summary['maxObservedSampleGapSeconds'], now-last)
            last = now
            summary['lastSampleElapsedSeconds'] = now-summary['startedMonotonic']
            summary['peakProcessTreeRSSBytes'] = max(summary['peakProcessTreeRSSBytes'], rss)
            summary['peakAdditionalSwapBytes'] = max(summary['peakAdditionalSwapBytes'], swap)
            summary['minimumSystemAvailableBytes'] = min(summary['minimumSystemAvailableBytes'], available)
            conditions = (available < args.min_available, rss > args.memory_budget, swap > args.max_swap_growth)
            bad = [count+1 if condition else 0 for count, condition in zip(bad, conditions)]
            reasons = ('本机可用内存过低', '修复进程超过内存预算', '系统新增交换空间过多')
            atomic_json(args.metrics, summary)
            if not args.ready_file.exists():
                atomic_json(args.ready_file, {'monitorPID': os.getpid(), 'guardedPID': args.parent_pid})
            for count, reason in zip(bad, reasons):
                if count >= args.consecutive and termination_deadline is None:
                    signal_owner(reason+'，已停止本次修复；原视频未修改。')
                    summary['exitReason'] = 'resource_limit'
                    termination_deadline = time.monotonic()+args.term_grace
            if termination_deadline is not None and time.monotonic() >= termination_deadline:
                # Python's TERM handler can be deferred by a native call holding
                # the GIL. Keep sampling during grace, then kill only this same
                # verified parent if it has not acknowledged stop or exited.
                if owner_matches(parent, args.parent_start_time):
                    parent.send_signal(signal.SIGKILL)
                    summary['signalsSent'].append('SIGKILL')
                summary['exitReason'] = 'resource_limit_escalated'
                return 0
            heartbeat(args.state, summary)
            deadline = now+args.interval
            while not STOP and not args.stop_file.exists() and time.monotonic() < deadline:
                if not owner_matches(parent, args.parent_start_time):
                    summary['exitReason'] = 'parent_exited'
                    return 0
                time.sleep(min(.1, max(0, deadline-time.monotonic())))
        if summary['exitReason'] is None:
            summary['exitReason'] = 'signal' if STOP else 'requested_stop'
        return 0
    except BrokenPipeError:
        # A closed host protocol pipe means the task no longer has an owner UI.
        summary['exitReason'] = 'protocol_closed'
        signal_owner('修复进程的状态通道已关闭，已停止本次任务。')
        finish_failed_monitor()
        return 1
    except BaseException:
        traceback.print_exc(file=sys.stderr)
        summary['exitReason'] = 'monitor_failure'
        with contextlib.suppress(Exception):
            signal_owner('独立资源监控发生异常，已停止本次修复。')
            finish_failed_monitor()
        return 1
    finally:
        summary['endedMonotonic'] = time.monotonic()
        with contextlib.suppress(OSError):
            atomic_json(args.metrics, summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent-pid', type=int, required=True)
    parser.add_argument('--parent-start-time', type=float, required=True)
    for name in ('state', 'metrics', 'stop-file', 'ready-file'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--memory-budget', type=int, required=True)
    parser.add_argument('--interval', type=float, default=2.0)
    parser.add_argument('--min-available', type=int, default=int(2.5*GIB))
    parser.add_argument('--max-swap-growth', type=int, default=int(1.5*GIB))
    parser.add_argument('--consecutive', type=int, default=3)
    parser.add_argument('--term-grace', type=float, default=10.0)
    args = parser.parse_args()
    if args.parent_pid <= 1 or args.parent_pid == os.getpid() or args.interval < .05 or args.consecutive < 1 or args.term_grace < 0:
        parser.error('invalid monitored identity or interval')
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    return run(args)


if __name__ == '__main__':
    sys.exit(main())
