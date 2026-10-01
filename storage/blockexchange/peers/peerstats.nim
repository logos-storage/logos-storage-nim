## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[deques, options, math]
import pkg/chronos

const
  RttSampleCount* = 16
  MinRequestsPerPeer* = 2
  MaxRequestsPerPeer* = 128
  DefaultRequestsPerPeer* = 2
  DefaultPipelineDepth* = 2
  MinThroughputDuration* = 100.milliseconds
  ThroughputWindow* = 3.seconds
  ProbeIntervalBatches* = 16
  ProbeWindowBatches* = 16
  GainThresholdPct* = 8
  LossThresholdPct* = 20
  MaxProbeBackoffShift* = 4

type
  ProbeMode* = enum
    Stable
    Probing

  ThroughputSample = object
    time: Moment
    cumBytes: uint64

  PeerPerfStats* = object
    rttSamples: Deque[uint64]
    throughputSamples: Deque[ThroughputSample]
    totalBytesDelivered: uint64
    currentDepth: int
    lastDepthChangeTime: Moment
    probeMode: ProbeMode
    probeBaselineBps: uint64
    probeStartTotalBytes: uint64
    probeStartTime: Moment
    batchesSinceProbe: int
    batchesInProbeWindow: int
    consecutiveReverts: int

proc new*(T: type PeerPerfStats): PeerPerfStats =
  PeerPerfStats(
    rttSamples: initDeque[uint64](RttSampleCount),
    throughputSamples: initDeque[ThroughputSample](),
    totalBytesDelivered: 0,
    currentDepth: DefaultRequestsPerPeer,
    lastDepthChangeTime: Moment.now(),
    probeMode: Stable,
    probeBaselineBps: 0,
    probeStartTotalBytes: 0,
    batchesSinceProbe: 0,
    batchesInProbeWindow: 0,
    consecutiveReverts: 0,
  )

proc trimThroughputWindow(self: var PeerPerfStats, now: Moment) =
  while self.throughputSamples.len > 0 and
      (now - self.throughputSamples[0].time) > ThroughputWindow:
    discard self.throughputSamples.popFirst()

proc avgThroughputBps(self: var PeerPerfStats, now: Moment): Option[uint64] =
  self.trimThroughputWindow(now)
  if self.throughputSamples.len < 2:
    return none(uint64)

  let
    first = self.throughputSamples[0]
    last = self.throughputSamples[self.throughputSamples.len - 1]
    duration = last.time - first.time

  if duration < MinThroughputDuration:
    return none(uint64)

  let
    delta = last.cumBytes - first.cumBytes
    secs = duration.nanoseconds.float64 / 1_000_000_000.0
  some((delta.float64 / secs).uint64)

proc avgRttMicros*(self: PeerPerfStats): Option[uint64] =
  if self.rttSamples.len == 0:
    return none(uint64)

  var total: uint64 = 0
  for sample in self.rttSamples:
    total += sample

  some(total div self.rttSamples.len.uint64)

proc throughputBps*(self: var PeerPerfStats): Option[uint64] =
  self.avgThroughputBps(Moment.now())

proc recordRequest*(self: var PeerPerfStats, rttMicros: uint64, bytes: uint64) =
  if self.rttSamples.len >= RttSampleCount:
    discard self.rttSamples.popFirst()
  self.rttSamples.addLast(rttMicros)

  let now = Moment.now()
  self.totalBytesDelivered += bytes
  self.throughputSamples.addLast(
    ThroughputSample(time: now, cumBytes: self.totalBytesDelivered)
  )
  self.trimThroughputWindow(now)

  self.batchesSinceProbe += 1
  if self.probeMode == Probing:
    self.batchesInProbeWindow += 1

proc computeBdpDepth(self: var PeerPerfStats, batchBytes: uint64, now: Moment): int =
  if batchBytes == 0:
    return DefaultPipelineDepth

  let rttMicrosOpt = self.avgRttMicros()
  if rttMicrosOpt.isNone:
    return DefaultRequestsPerPeer

  let throughputOpt = self.avgThroughputBps(now)
  if throughputOpt.isNone:
    return DefaultRequestsPerPeer

  let
    rttMicros = rttMicrosOpt.get()
    throughput = throughputOpt.get()
    rttSecs = rttMicros.float64 / 1_000_000.0
    bdpBytes = throughput.float64 * rttSecs
    depth = ceil(bdpBytes / batchBytes.float64).int
  clamp(depth, MinRequestsPerPeer, MaxRequestsPerPeer)

proc optimalPipelineDepth*(self: var PeerPerfStats, batchBytes: uint64): int =
  let now = Moment.now()

  case self.probeMode
  of Stable:
    let
      bdpDepth = self.computeBdpDepth(batchBytes, now)
      gracePassed = (now - self.lastDepthChangeTime) >= ThroughputWindow

    if bdpDepth < self.currentDepth and gracePassed:
      self.currentDepth = max(MinRequestsPerPeer, bdpDepth)
      self.lastDepthChangeTime = now

    let effectiveInterval =
      ProbeIntervalBatches * (1 shl min(self.consecutiveReverts, MaxProbeBackoffShift))
    if self.batchesSinceProbe >= effectiveInterval and
        self.currentDepth < MaxRequestsPerPeer:
      let baseline = self.avgThroughputBps(now)
      if baseline.isSome:
        self.probeBaselineBps = baseline.get()
        self.probeStartTotalBytes = self.totalBytesDelivered
        self.probeStartTime = now
        self.probeMode = Probing
        self.batchesInProbeWindow = 0
        self.currentDepth = self.currentDepth + 1
        self.lastDepthChangeTime = now

    return self.currentDepth
  of Probing:
    if self.batchesInProbeWindow < ProbeWindowBatches:
      return self.currentDepth

    let
      probeBytes = self.totalBytesDelivered - self.probeStartTotalBytes
      probeDuration = now - self.probeStartTime
      probeDurationSecs = probeDuration.nanoseconds.float64 / 1_000_000_000.0

    if probeDurationSecs > 0 and self.probeBaselineBps > 0:
      let
        probeBps = (probeBytes.float64 / probeDurationSecs).uint64
        baselineBps = self.probeBaselineBps
        deltaPct = ((probeBps.int64 - baselineBps.int64) * 100) div baselineBps.int64

      if deltaPct >= GainThresholdPct:
        self.consecutiveReverts = 0
        self.lastDepthChangeTime = now
      elif deltaPct <= -LossThresholdPct:
        self.consecutiveReverts = 0
        self.currentDepth = max(MinRequestsPerPeer, self.currentDepth - 2)
        self.lastDepthChangeTime = now
      else:
        self.consecutiveReverts += 1
        self.currentDepth = max(MinRequestsPerPeer, self.currentDepth - 1)
        self.lastDepthChangeTime = now
    else:
      self.consecutiveReverts += 1
      self.currentDepth = max(MinRequestsPerPeer, self.currentDepth - 1)
      self.lastDepthChangeTime = now

    self.probeMode = Stable
    self.batchesSinceProbe = 0
    self.batchesInProbeWindow = 0
    self.probeBaselineBps = 0
    self.probeStartTotalBytes = 0
    return self.currentDepth

proc sampleCount*(self: PeerPerfStats): int =
  self.rttSamples.len

proc reset*(self: var PeerPerfStats) =
  self.rttSamples.clear()
  self.throughputSamples.clear()
  self.totalBytesDelivered = 0
  self.currentDepth = DefaultRequestsPerPeer
  self.lastDepthChangeTime = Moment.now()
  self.probeMode = Stable
  self.probeBaselineBps = 0
  self.probeStartTotalBytes = 0
  self.batchesSinceProbe = 0
  self.batchesInProbeWindow = 0
  self.consecutiveReverts = 0
