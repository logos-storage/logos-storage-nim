import std/options
import std/sequtils

import pkg/toml_serialization
import pkg/unittest2

import pkg/storage/presets
import pkg/storage/conf

const SPRs = [
  "spr:CiUIAhIhA-VlcoiRm02KyIzrcTP-ljFpzTljfBRRKTIvhMIwqBqWEgIDARpJCicAJQgCEiED5WVyiJGbTYrIjOtxM_6" &
    "WMWnNOWN8FFEpMi-EwjCoGpYQs8n8wQYaCwoJBHTKubmRAnU6GgsKCQR0yrm5kQJ1OipHMEUCIQDwUNsfReB4ty7JFS" &
    "5WVQ6n1fcko89qVAOfQEHixa03rgIgan2-uFNDT-r4s9TOkLe9YBkCbsRWYCHGGVJ25rLj0QE",
  "spr:CiUIAhIhApIj9p6zJDRbw2NoCo-tj98Y760YbppRiEpGIE1yGaMzEgIDARpJCicAJQgCEiECkiP2nrMkNFvDY2gKj62P" &
    "3xjvrRhumlGISkYgTXIZozMQvcz8wQYaCwoJBAWhF3WRAnVEGgsKCQQFoRd1kQJ1RCpGMEQCIFZB84O_nzPNuViqEGRL" &
    "1vJTjHBJ-i5ZDgFL5XZxm4HAAiB8rbLHkUdFfWdiOmlencYVn0noSMRHzn4lJYoShuVzlw",
]

# Construct presets as const to make sure that everything we do
# on `init` runs properly in VM (e.g. parsing SPRs in VM is a
# no-go because of: https://github.com/nim-lang/Nim/issues/23468)
const Presets = [
  NetworkPreset.init("preset1", "a preset", SPRs.toSeq),
  NetworkPreset.init("preset2", "empty preset", @[]),
]

type TestConfig = object
  network: NetworkPreset

suite "Network presets":
  test "should construct presets correctly":
    check Presets[0].name == "preset1"
    check Presets[0].description == "a preset"

    check Presets[0].bootstrapNodes.len == 2
    check Presets[0].rawRecords == @SPRs

  test "should find existing presets by name":
    let
      preset1 = Presets.find("preset1").get()
      preset2 = Presets.find("preset2").get()

    check preset1.name == "preset1"
    check preset2.name == "preset2"

  test "should return error when preset is not found":
    let result = Presets.find("nonexistent")
    check result.isNone

  test "should return presets matching prefix":
    let result = Presets.findByPrefix("preset")
    check result.len == 2
    check result[0] == "preset1"
    check result[1] == "preset2"

    let result2 = Presets.findByPrefix("preset1")
    check result2.len == 1
    check result2[0] == "preset1"

  test "should deserialize valid preset from TOML":
    # Sadly, we have no option but reading from the global presets array
    # here, unless we really want to complicate things.
    let toml = """
      network = "logos.dev"
    """
    let config = Toml.decode(toml, TestConfig)
    check config.network.name == "logos.dev"

  test "should raise SerializationError for invalid preset":
    let toml = """
      network = "nonexistent"
    """
    expect SerializationError:
      discard Toml.decode(toml, TestConfig)
