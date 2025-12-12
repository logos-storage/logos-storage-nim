import std/[hashes, json, strutils, strformat, os, osproc, uri]

import ./utils

type
  CircuitEnv* = object
    nimCircuitCli*: string
    circuitLibDirIncludes*: string
    circuitPoseidon2DirIncludes*: string
    circuitCodexDirIncludes*: string
    ptauPath*: string
    ptauUrl*: Uri
    codexProjDir*: string

  CircuitArgs* = object
    depth*: int
    maxslots*: int
    cellsize*: int
    blocksize*: int
    nsamples*: int
    entropy*: int
    seed*: int
    nslots*: int
    ncells*: int
    index*: int

proc findCodexProjectDir(): string =
  ## find codex proj dir -- assumes this script is in codex/benchmarks
  result = currentSourcePath().parentDir.parentDir

func default*(tp: typedesc[CircuitEnv]): CircuitEnv =
  let
    codexDir = findCodexProjectDir()
    baseCircuitDir = codexDir / "vendor" / "codex-storage-proofs-circuits" / "circuit"

  result.nimCircuitCli =
    codexDir / "vendor" / "codex-storage-proofs-circuits" / "reference" / "nim" /
    "proof_input" / "cli"
  result.circuitLibDirIncludes = baseCircuitDir / "lib"
  result.circuitPoseidon2DirIncludes = baseCircuitDir / "poseidon2"
  result.circuitCodexDirIncludes = baseCircuitDir / "codex"
  result.ptauPath =
    codexDir / "benchmarks" / "ceremony" / "powersOfTau28_hez_final_23.ptau"
  result.ptauUrl = "https://storage.googleapis.com/zkevm/ptau".parseUri
  result.codexProjDir = codexDir

proc check*(env: var CircuitEnv) =
  ## check that the CWD of script is in the codex parent
  let codexProjDir = findCodexProjectDir()
  echo "\n\nFound project dir: ", codexProjDir

  let snarkjs = findExe("snarkjs")
  if snarkjs == "":
    echo dedent"""
    ERROR: must install snarkjs first

      npm install -g snarkjs@latest
    """

  let circom = findExe("circom")
  if circom == "":
    echo dedent"""
    ERROR: must install circom first

      git clone https://github.com/iden3/circom.git
      cargo install --path circom
    """

  if snarkjs == "" or circom == "":
    quit 2

  echo "Found SnarkJS: ", snarkjs
  echo "Found Circom: ", circom

  if not env.nimCircuitCli.fileExists:
    echo "Nim Circuit reference cli not found: ", env.nimCircuitCli
    echo "Building Circuit reference cli...\n"
    withDir env.nimCircuitCli.parentDir:
      runit "nimble build -d:release --styleCheck:off cli"
    echo "CWD: ", getCurrentDir()
    assert env.nimCircuitCli.fileExists()

  echo "Found NimCircuitCli: ", env.nimCircuitCli
  echo "Found Circuit-lib Path: ", env.circuitLibDirIncludes
  echo "Found Circuit-poseidon2 Path: ", env.circuitPoseidon2DirIncludes
  echo "Found Circuit-codex Path: ", env.circuitCodexDirIncludes
  echo "Found PTAU file: ", env.ptauPath

proc downloadPtau*(ptauPath: string, ptauUrl: Uri) =
  ## download ptau file using curl if needed
  if not ptauPath.fileExists:
    echo "Ceremony file not found, downloading..."
    createDir ptauPath.parentDir
    withDir ptauPath.parentDir:
      runit fmt"curl --output '{ptauPath}' '{$ptauUrl}/{ptauPath.splitPath().tail}'"
  else:
    echo "Found PTAU file at: ", ptauPath

proc getCircuitBenchStr*(args: CircuitArgs): string =
  for f, v in fieldPairs(args):
    result &= "_" & f & $v

proc getCircuitBenchPath*(args: CircuitArgs, env: CircuitEnv): string =
  ## generate folder name for unique circuit args
  result = env.codexProjDir / "benchmarks/circuit_bench" & getCircuitBenchStr(args)

proc generateCircomAndSamples*(args: CircuitArgs, env: CircuitEnv, name: string) =
  ## run nim circuit and sample generator 
  var cliCmd = env.nimCircuitCli
  for f, v in fieldPairs(args):
    cliCmd &= " --" & f & "=" & $v

  if not "input.json".fileExists:
    echo "Generating Circom Files..."
    runit fmt"{cliCmd} -v --field=bn254 --hash=poseidon2 --circom={name}.circom --output=input.json"

proc createCircuit*(
    args: CircuitArgs,
    env: CircuitEnv,
    name = "proof_main",
    circBenchDir = getCircuitBenchPath(args, env),
    someEntropy = "some_entropy_75289v3b7rcawcsyiur",
    doGenerateWitness = false,
): tuple[dir: string, name: string] =
  ## Generates all the files needed for to run a proof circuit. Downloads the PTAU file if needed.
  ## 
  ## All needed circuit files will be generated as needed. 
  ## They will be located in `circBenchDir` which defaults to a folder like:
  ##    `nim-codex/benchmarks/circuit_bench_depth32_maxslots256_cellsize2048_blocksize65536_nsamples9_entropy1234567_seed12345_nslots11_ncells512_index3`
  ## with all the given CircuitArgs.
  ## 
  let circdir = circBenchDir

  downloadPtau env.ptauPath, env.ptauUrl

  echo "Creating circuit dir: ", circdir
  createDir circdir
  withDir circdir:
    writeFile("circuit_params.json", pretty(%*args))
    let
      inputs = circdir / "input.json"
      zkey = circdir / fmt"{name}.zkey"
      wasm = circdir / fmt"{name}.wasm"
      r1cs = circdir / fmt"{name}.r1cs"
      wtns = circdir / fmt"{name}.wtns"

    generateCircomAndSamples(args, env, name)

    if not wasm.fileExists or not r1cs.fileExists:
      runit fmt"circom --r1cs --wasm --O2 -l{env.circuitLibDirIncludes} -l{env.circuitPoseidon2DirIncludes} -l{env.circuitCodexDirIncludes} {name}.circom"
      moveFile fmt"{name}_js" / fmt"{name}.wasm", fmt"{name}.wasm"
    echo "Found wasm: ", wasm
    echo "Found r1cs: ", r1cs

    if not zkey.fileExists:
      echo "ZKey not found, generating..."
      putEnv "NODE_OPTIONS", "--max-old-space-size=8192"
      if not fmt"{name}_0000.zkey".fileExists:
        runit fmt"snarkjs groth16 setup {r1cs} {env.ptauPath} {name}_0000.zkey"
        echo fmt"Generated {name}_0000.zkey"

      let cmd =
        fmt"snarkjs zkey contribute {name}_0000.zkey {name}_0001.zkey --name='1st Contributor Name'"
      echo "CMD: ", cmd
      let cmdRes = execCmdEx(cmd, options = {}, input = someEntropy & "\n")
      assert cmdRes.exitCode == 0

      moveFile fmt"{name}_0001.zkey", fmt"{name}.zkey"
      removeFile fmt"{name}_0000.zkey"

    if not wtns.fileExists and doGenerateWitness:
      runit fmt"node generate_witness.js {wtns} ../input.json ../witness.wtns"

  return (circdir, name)

when isMainModule:
  echo "findCodexProjectDir: ", findCodexProjectDir()
  ## test run creating a circuit
  var env = CircuitEnv.default()
  env.check()

  let args = CircuitArgs(
    depth: 32, # maximum depth of the slot tree 
    maxslots: 256, # maximum number of slots
    cellsize: 2048, # cell size in bytes 
    blocksize: 65536, # block size in bytes 
    nsamples: 5, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: 11, # number of slots in the dataset
    index: 3, # which slot we prove (0..NSLOTS-1)
    ncells: 512, # number of cells in this slot
  )
  let benchenv = createCircuit(args, env)
  echo "\nBench dir:\n", benchenv
