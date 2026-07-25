# APC coalescing CPU use and proposed Wine fix

Live's APC coalescing thread uses 30 to 40% of one CPU core while idle.
Release 2026.07.18.1 added `-DontCombineAPCs`, which removed that load but
caused choppy, slowed playback. Removing the option fixed issue #29 on the
reporter's machine; restoring it reproduced the fault. Release 2026.07.19.1
removed the option and strips it from existing prefixes.

The Wine-side fix below is a proposal. Its account of Live's internals has
not been confirmed by profiling.

## Current hypothesis

Live appears to batch engine asynchronous procedure calls (APCs) with a
high-frequency alertable wait. Wine sends each alertable wait through the
wineserver. ntsync accelerates handle waits, but not alertable sleeps or APC
delivery. A loop near 1 kHz would explain the measured CPU use.

Confirm this before writing a patch. Run an idle session with
`WINEDEBUG=+server`, then count `select` and `queue_apc` calls from the
coalescing thread with and without `-DontCombineAPCs`.

With coalescing disabled, each engine APC appears to require its own
`NtQueueApcThread` request and target-thread wake. The single-threaded
wineserver serializes those requests. The hypothesis predicts that this
serialization makes PipeASIO miss graph cycles under playback load. This
explanation fits the reported audio and video stutter, but still needs a
trace.

## Proposed implementation

ntsync waits already accept an alert event for APC delivery. A Wine patch
could use that event for same-process user APCs:

1. `NtQueueApcThread` adds a same-process user APC to a per-thread queue and
   signals the target thread's ntsync alert event.
2. An alertable wait drains that queue before checking the existing
   server-side APC queue.
3. Cross-process and system APCs continue through wineserver. Wineserver
   delivery continues to signal the same alert event.

The patch must preserve FIFO order across both queues, `NtTestAlert`,
suspend and termination behavior, special user APCs, and I/O completion
ordering. Add an `apcprobe` to the tester kit, following the existing
`ntsyncprobe` pattern. Run it against the unpatched build first, then require
the same results from the patch.

## Verification

Compare unpatched and patched builds with `ABLETON_RT=on` and `off`. Repeat
each pair with all available CPUs and with four CPUs allowed by the current
cpuset; see
[ABLETON-WINE-RT-SCHEDULING.md](ABLETON-WINE-RT-SCHEDULING.md).

For idle tests, open the ASIO device at 256 samples and stop transport.
Record the coalescing thread's CPU use, wineserver CPU use, and context
switches.

For playback, run the fixed reference set for five minutes. Record the
PipeASIO node's `pw-top` xrun delta and wineserver CPU use. The existing
`scripts/bench-run.sh` accepts the five-minute xrun count and DSP load, and
records `wined3d_cs` CPU use plus wineserver context switches. Record the
APC-specific CPU figures separately unless that script is extended.

Require all of these results:

- No more playback xruns than the unpatched baseline. The previous baseline
  was zero.
- Every `apcprobe` assertion passes.
- Idle coalescing-thread CPU use stays below 5%.

Run the beta tester kit before release. Release 2026.07.19.1 showed that an
idle-only measurement is not enough for an audio-processing change.

## Current status

This proposal remains unimplemented. Current releases retain Live's default
APC coalescing and its measured idle CPU use. Prefix setup only removes the
known-bad `-DontCombineAPCs` line from `Options.txt`.
