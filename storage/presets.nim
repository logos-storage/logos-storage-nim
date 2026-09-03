# Presets are hard-coded configuration bundles that get compiled into code. They can refer
# to different things, but the canonical example are sets of bootstrap nodes that define
# logically different networks; e.g., "logos.dev" and "logos.test" refer to the Logos
# devnet and latest testnet, respectively.
import std/options
import std/strutils
import std/json

import pkg/chronicles
import pkg/libp2p/routing_record
import pkg/results

import ./utils/spr

# A NetworkPreset is a set of bootstrap nodes (represented
# by their signed peer records) along with some description metadata.
type NetworkPreset* = object
  name*: string
  description*: string
  unparsedRecords: seq[string]

proc init*(
    T: type NetworkPreset, name: string, description: string, records: seq[string]
): T =
  result.name = name
  result.description = description

  # We have to delay parsing of records to runtime because
  # of https://github.com/nim-lang/Nim/issues/23468
  result.unparsedRecords = records

func `$`*(preset: NetworkPreset): string =
  "[" & preset.name & "]: " & preset.description

func describePresets(presets: openArray[NetworkPreset]): string =
  result = ""
  for preset in presets:
    result &= $preset & "; "

proc `bootstrapNodes`*(self: NetworkPreset): seq[SignedPeerRecord] =
  for record in self.unparsedRecords:
    # Having an invalid SPR in a hardcoded config is a bug, a+
    # it should crash the node.
    result.add(SignedPeerRecord.parse(record).tryGet())

# Bootstrap node SPRs live in a single source-of-truth config file at the repo
# root. staticRead embeds it into the binary at build time, so the node remains
# self-contained (the file is not needed alongside the binary at runtime). The
# same file is read at runtime by the bootstrap liveness checker (tools/check_spr).
const networkPresetsJson = staticRead("../network_presets.json")

proc parsePresetsJson(jsonStr: string): seq[NetworkPreset] =
  let root = parseJson(jsonStr)
  for p in root["presets"].items:
    var records: seq[string]
    for r in p["records"].items:
      records.add(r.getStr)
    result.add(NetworkPreset.init(p["name"].getStr, p["description"].getStr, records))

const NetworkPresets* = parsePresetsJson(networkPresetsJson)

proc loadNetworkPresets*(path: string): seq[NetworkPreset] =
  ## Runtime loader for the same bootstrap-node config file embedded at compile
  ## time into `NetworkPresets`. Used by the bootstrap liveness checker so the
  ## node and the checker share one source of truth.
  parsePresetsJson(readFile(path))

proc rawRecords*(self: NetworkPreset): seq[string] =
  ## The unparsed `spr:` strings for this preset (for tooling that wants to
  ## handle parse failures per-record instead of crashing).
  self.unparsedRecords

proc `default`*(presets: openArray[NetworkPreset]): NetworkPreset =
  presets[0]

# Precomputes those as as consts so we can use them in nim-confutils CLI
# help strings.
const
  NetworkPresetsDescription* = describePresets(NetworkPresets)
  DefaultNetworkPreset* = NetworkPresets.default

proc find*(presets: openArray[NetworkPreset], p: string): Option[NetworkPreset] =
  for preset in presets:
    if preset.name == p:
      return some(preset)
  return none(NetworkPreset)

proc findByPrefix*(presets: openArray[NetworkPreset], val: string): seq[string] =
  for p in presets:
    if p.name.startsWith(val):
      result.add p.name
