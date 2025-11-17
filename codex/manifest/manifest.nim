## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines all operations on Manifest

{.push raises: [], gcsafe.}

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/[cid, multihash, multicodec]
import pkg/questionable/results

import ../errors
import ../utils
import ../utils/json
import ../units
import ../blocktype
import ../indexingstrategy
import ../logutils

# TODO: Manifest should be reworked to more concrete types,
# perhaps using inheritance
type Manifest* = ref object of RootObj
  treeCid {.serialize.}: Cid # Root of the merkle tree
  datasetSize {.serialize.}: NBytes # Total size of all blocks
  blockSize {.serialize.}: NBytes
    # Size of each contained block (might not be needed if blocks are len-prefixed)
  codec: MultiCodec # Dataset codec
  hcodec: MultiCodec # Multihash codec
  version: CidVersion # Cid version
  filename {.serialize.}: ?string # The filename of the content uploaded (optional)
  mimetype {.serialize.}: ?string # The mimetype of the content uploaded (optional)
  case protected {.serialize.}: bool # Protected datasets have erasure coded info
  of true:
    ecK: int # Number of blocks to encode
    ecM: int # Number of resulting parity blocks
    originalTreeCid: Cid # The original root of the dataset being erasure coded
    originalDatasetSize: NBytes
    protectedStrategy: StrategyType # Indexing strategy used to build the slot roots
    case verifiable {.serialize.}: bool
    # Verifiable datasets can be used to generate storage proofs
    of true:
      verifyRoot: Cid # Root of the top level merkle tree built from slot roots
      slotRoots: seq[Cid] # Individual slot root built from the original dataset blocks
      cellSize: NBytes # Size of each slot cell
      verifiableStrategy: StrategyType # Indexing strategy used to build the slot roots
    else:
      discard
  else:
    discard

############################################################
# Accessors
############################################################

func blockSize*(self: Manifest): NBytes =
  self.blockSize

func datasetSize*(self: Manifest): NBytes =
  self.datasetSize

func version*(self: Manifest): CidVersion =
  self.version

func hcodec*(self: Manifest): MultiCodec =
  self.hcodec

func codec*(self: Manifest): MultiCodec =
  self.codec

func protected*(self: Manifest): bool =
  self.protected

func ecK*(self: Manifest): int =
  self.ecK

func ecM*(self: Manifest): int =
  self.ecM

func originalTreeCid*(self: Manifest): Cid =
  self.originalTreeCid

func originalBlocksCount*(self: Manifest): int =
  divUp(self.originalDatasetSize.int, self.blockSize.int)

func originalDatasetSize*(self: Manifest): NBytes =
  self.originalDatasetSize

func treeCid*(self: Manifest): Cid =
  self.treeCid

func blocksCount*(self: Manifest): int =
  divUp(self.datasetSize.int, self.blockSize.int)

func verifiable*(self: Manifest): bool =
  bool (self.protected and self.verifiable)

func verifyRoot*(self: Manifest): Cid =
  self.verifyRoot

func slotRoots*(self: Manifest): seq[Cid] =
  self.slotRoots

func numSlots*(self: Manifest): int =
  self.ecK + self.ecM

func cellSize*(self: Manifest): NBytes =
  self.cellSize

func protectedStrategy*(self: Manifest): StrategyType =
  self.protectedStrategy

func verifiableStrategy*(self: Manifest): StrategyType =
  self.verifiableStrategy

func numSlotBlocks*(self: Manifest): int =
  divUp(self.blocksCount, self.numSlots)

func filename*(self: Manifest): ?string =
  self.filename

func mimetype*(self: Manifest): ?string =
  self.mimetype

############################################################
# Operations on block list
############################################################

func isManifest*(cid: Cid): ?!bool =
  success (ManifestCodec == ?cid.contentType().mapFailure(CodexError))

func isManifest*(mc: MultiCodec): ?!bool =
  success mc == ManifestCodec

############################################################
# Various sizes and verification
############################################################

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalBlocksCount, self.ecK)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.rounded, self.ecK)

func verify*(self: Manifest): ?!void =
  ## Check manifest correctness
  ##

  if self.protected and (self.blocksCount != self.steps * (self.ecK + self.ecM)):
    return
      failure newException(CodexError, "Broken manifest: wrong originalBlocksCount")

  return success()

func `==`*(a, b: Manifest): bool =
  (a.treeCid == b.treeCid) and (a.datasetSize == b.datasetSize) and
    (a.blockSize == b.blockSize) and (a.version == b.version) and (a.hcodec == b.hcodec) and
    (a.codec == b.codec) and (a.protected == b.protected) and (a.filename == b.filename) and
    (a.mimetype == b.mimetype) and (
    if a.protected:
      (a.ecK == b.ecK) and (a.ecM == b.ecM) and (a.originalTreeCid == b.originalTreeCid) and
        (a.originalDatasetSize == b.originalDatasetSize) and
        (a.protectedStrategy == b.protectedStrategy) and (a.verifiable == b.verifiable) and
      (
        if a.verifiable:
          (a.verifyRoot == b.verifyRoot) and (a.slotRoots == b.slotRoots) and
            (a.cellSize == b.cellSize) and (
            a.verifiableStrategy == b.verifiableStrategy
          )
        else:
          true
      )
    else:
      true
  )

func `$`*(self: Manifest): string =
  result =
    "treeCid: " & $self.treeCid & ", datasetSize: " & $self.datasetSize & ", blockSize: " &
    $self.blockSize & ", version: " & $self.version & ", hcodec: " & $self.hcodec &
    ", codec: " & $self.codec & ", protected: " & $self.protected

  if self.filename.isSome:
    result &= ", filename: " & $self.filename

  if self.mimetype.isSome:
    result &= ", mimetype: " & $self.mimetype

  result &= (
    if self.protected:
      ", ecK: " & $self.ecK & ", ecM: " & $self.ecM & ", originalTreeCid: " &
        $self.originalTreeCid & ", originalDatasetSize: " & $self.originalDatasetSize &
        ", verifiable: " & $self.verifiable & (
        if self.verifiable:
          ", verifyRoot: " & $self.verifyRoot & ", slotRoots: " & $self.slotRoots
        else:
          ""
      )
    else:
      ""
  )

  return result

############################################################
# Constructors
############################################################

func new*(
    T: type Manifest,
    treeCid: Cid,
    blockSize: NBytes,
    datasetSize: NBytes,
    version: CidVersion = CIDv1,
    hcodec = Sha256HashCodec,
    codec = BlockCodec,
    protected = false,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  T(
    treeCid: treeCid,
    blockSize: blockSize,
    datasetSize: datasetSize,
    version: version,
    codec: codec,
    hcodec: hcodec,
    protected: protected,
    filename: filename,
    mimetype: mimetype,
  )

func new*(
    T: type Manifest,
    manifest: Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    ecK, ecM: int,
    strategy = SteppedStrategy,
): Manifest =
  ## Create an erasure protected dataset from an
  ## unprotected one
  ##

  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: manifest.treeCid,
    originalDatasetSize: manifest.datasetSize,
    protectedStrategy: strategy,
    filename: manifest.filename,
    mimetype: manifest.mimetype,
  )

func new*(T: type Manifest, manifest: Manifest): Manifest =
  ## Create an unprotected dataset from an
  ## erasure protected one
  ##

  Manifest(
    treeCid: manifest.originalTreeCid,
    datasetSize: manifest.originalDatasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: false,
    filename: manifest.filename,
    mimetype: manifest.mimetype,
  )

func new*(
    T: type Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    blockSize: NBytes,
    version: CidVersion,
    hcodec: MultiCodec,
    codec: MultiCodec,
    ecK: int,
    ecM: int,
    originalTreeCid: Cid,
    originalDatasetSize: NBytes,
    strategy = SteppedStrategy,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: originalTreeCid,
    originalDatasetSize: originalDatasetSize,
    protectedStrategy: strategy,
    filename: filename,
    mimetype: mimetype,
  )

func new*(
    T: type Manifest,
    manifest: Manifest,
    verifyRoot: Cid,
    slotRoots: openArray[Cid],
    cellSize = DefaultCellSize,
    strategy = LinearStrategy,
): ?!Manifest =
  ## Create a verifiable dataset from an
  ## protected one
  ##

  if not manifest.protected:
    return failure newException(
      CodexError, "Can create verifiable manifest only from protected manifest."
    )

  if slotRoots.len != manifest.numSlots:
    return failure newException(CodexError, "Wrong number of slot roots.")

  success Manifest(
    treeCid: manifest.treeCid,
    datasetSize: manifest.datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    ecK: manifest.ecK,
    ecM: manifest.ecM,
    originalTreeCid: manifest.originalTreeCid,
    originalDatasetSize: manifest.originalDatasetSize,
    protectedStrategy: manifest.protectedStrategy,
    verifiable: true,
    verifyRoot: verifyRoot,
    slotRoots: @slotRoots,
    cellSize: cellSize,
    verifiableStrategy: strategy,
    filename: manifest.filename,
    mimetype: manifest.mimetype,
  )

func new*(T: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Create a manifest instance from given data
  ##

  Manifest.decode(data)
