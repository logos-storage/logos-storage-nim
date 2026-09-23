## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[math, options]

import pkg/libp2p
import pkg/chronos
import pkg/questionable

import ./peerstats

const
  WeightCapacity* = 0.30
  WeightThroughput* = 0.25
  WeightRtt* = 0.25
  WeightPenalty* = 0.20

  BestRatio* = 0.0
  WorstRatio* = 1.0

  # Absolute reference points for normalization. Peers far beyond these
  # saturate at BestRatio or WorstRatio.
  RefMaxBps* = 104_857_600.0 # 100 MiB/s — peer implementation's peak throughput
  RefMaxRttMicros* = 500_000.0 # 500 ms
  RefMaxPenalty* = 15.0 # e.g. ~5 failures at TimeoutPenaltyWeight=3

  # Fallback ratios used when a peer lacks a specific metric.
  # 0.5 places the peer mid-range so it's neither preferred nor punished.
  FallbackThroughputRatio* = 0.5
  FallbackRttRatio* = 0.5

  DefaultBatchTimeout* = 300.seconds # fallback when no BDP stats available
  TimeoutSafetyFactor* = 3.0
    # multiplier to account for variance (network jitter, congestion, GC pauses )
  MinBatchTimeout* = 5.seconds # min to avoid too aggressive timeouts
  MaxBatchTimeout* = 45.seconds # max to handle high contention scenarios

static:
  doAssert (WeightCapacity + WeightThroughput + WeightRtt + WeightPenalty) == 1.0,
    "BDP score weights must sum to 1.0"

type PeerContext* = ref object of RootObj
  id*: PeerId
  stats*: PeerPerfStats
  wantListBusy*: bool

proc new*(T: type PeerContext, id: PeerId): PeerContext =
  PeerContext(id: id, stats: PeerPerfStats.new())

proc optimalPipelineDepth*(self: PeerContext, batchBytes: uint64): int =
  self.stats.optimalPipelineDepth(batchBytes)

proc batchTimeout*(self: PeerContext, batchBytes: uint64): Duration =
  ## find optimal timeout for a batch based on BDP
  ## timeout = min((batchBytes / throughput + RTT) * safetyFactor, maxTimeout)
  ## it falls back to default if no stats available.
  let
    throughputOpt = self.stats.throughputBps()
    rttOpt = self.stats.avgRttMicros()

  if throughputOpt.isNone or rttOpt.isNone:
    return DefaultBatchTimeout

  let
    throughput = throughputOpt.get()
    rttMicros = rttOpt.get()

  if throughput == 0:
    return DefaultBatchTimeout

  let
    transferTimeMicros = (batchBytes * 1_000_000) div throughput
    totalTimeMicros = transferTimeMicros + rttMicros
    timeoutMicros = (totalTimeMicros.float * TimeoutSafetyFactor).uint64
    timeout = microseconds(timeoutMicros.int64)

  if timeout < MinBatchTimeout:
    return MinBatchTimeout

  if timeout > MaxBatchTimeout:
    return MaxBatchTimeout

  return timeout

proc evalBDPScore*(
    self: PeerContext, batchBytes: uint64, currentLoad: int, penalty: float
): float =
  ## Weighted sum of normalized components. Each component is in [0, 1]
  ## where 0 = best and 1 = worst. Lower final score is better.
  let
    pipelineDepth = self.optimalPipelineDepth(batchBytes)
    capacityRatio =
      if currentLoad >= pipelineDepth:
        WorstRatio
      elif pipelineDepth > 0:
        currentLoad.float / pipelineDepth.float
      else:
        WorstRatio

    throughputRatio =
      if self.stats.throughputBps().isSome:
        let bps = self.stats.throughputBps().get().float
        if bps <= 0:
          WorstRatio
        else:
          clamp(WorstRatio - bps / RefMaxBps, BestRatio, WorstRatio)
      else:
        FallbackThroughputRatio

    rttRatio =
      if self.stats.avgRttMicros().isSome:
        clamp(
          self.stats.avgRttMicros().get().float / RefMaxRttMicros, BestRatio, WorstRatio
        )
      else:
        FallbackRttRatio

    penaltyRatio = clamp(penalty / RefMaxPenalty, BestRatio, WorstRatio)

  WeightCapacity * capacityRatio + WeightThroughput * throughputRatio +
    WeightRtt * rttRatio + WeightPenalty * penaltyRatio
