## name_record - signs a name record with a private key, for a CI.
##
## A CI that is not a Storage node publishes a name with its own key: this tool
## signs the name record, then the CI sends it to a node with the refresh call.
## The node validates the name record and advertises it in the DHT. It doesn't
## keep it and doesn't republish it.
##
## Usage:
##   name_record --key-file <path|-> --label <label> --cid <cid> [--seqnum <n>]
##   name_record --help
##
## Run `name_record --help` for a full description of every option.

import std/[json, os, strutils, times]

import pkg/libp2p
import pkg/results
import pkg/stew/base64

import ../storage/naming/publisher
import ../storage/utils/fileutils
import ../storage/utils/nameutils

proc printHelp() =
  echo """name_record - signs a name record with a private key, for a CI.

Examples:
  record=$(name_record --key-file ci.key --label catalog --cid "$cid" | jq -r .record)

  echo "$KEY" | name_record --key-file - --label catalog --cid "$cid" --seqnum 7

  curl -X POST --data "$record" -H 'Content-Type: text/plain' \
    http://<node>/api/storage/v1/names/<nameKey>/refresh

The output is a JSON object on stdout:
  {"nameKey": "<name key>", "record": "<signed name record in base64url>"}

The <nameKey> of the curl call is the "nameKey" of the output.
The node validates the name record and advertises it in the DHT. It doesn't
keep it, so the CI sends it again before it expires.

Usage:
  name_record --key-file <path|-> --label <label> --cid <cid> [--seqnum <n>]

Options:
  --key-file <path|->  The private key: one line with the base64url of the
                       libp2p serialized private key (secp256k1), the content of
                       the key file of a node. Use - to read it from stdin.
                       A file that other users can read or write is refused.
  --label <label>      The label of the name, from 1 to 256 bytes of UTF-8.
  --cid <cid>          The CID (CIDv1) the name points to.
  --seqnum <n>         The sequence number of the name record. It must grow with
                       each new name record of the same name (default: the
                       current Unix time in seconds).
  --help, -h           Show this help and exit.

The name record expires 8 hours after it is signed."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine("Error: " & message)
  quit(QuitFailure)

proc nextValue(params: seq[string], i: var int, flag: string): string =
  ## The value that follows a value-expecting flag. A lone `-` is a value, any
  ## other token that starts with `-` is a flag.
  inc i

  if i >= params.len or (params[i].startsWith("-") and params[i] != "-"):
    fail(flag & " requires a value, see --help")

  params[i]

proc parseSeqnum(value: string): uint64 =
  try:
    parseBiggestUInt(value).uint64
  except ValueError:
    fail("--seqnum must be a positive integer, got '" & value & "'")

proc readKeyLine(keyFile: string): string =
  ## The first line of the key file, or of stdin when the key file is `-`.
  if keyFile == "-":
    var line: string

    try:
      if not stdin.readLine(line):
        fail("stdin is empty: expected the private key on one line")
    except IOError as exc:
      fail("cannot read the private key from stdin: " & exc.msg)

    return line.strip()

  let secure = checkSecureFile(keyFile).valueOr:
    fail(
      "cannot check the permissions of '" & keyFile & "': " & $error &
        ". Does the file exist?"
    )

  if not secure:
    fail(
      "the key file '" & keyFile & "' is not safe: only its owner can read and write it. " &
        "Fix it with: chmod 600 " & keyFile
    )

  try:
    return readFile(keyFile).splitLines()[0].strip()
  except IOError as exc:
    fail("cannot read the key file '" & keyFile & "': " & exc.msg)

proc parsePrivateKey(line: string): PrivateKey =
  ## The key is the base64url of the serialized private key.
  var bytes: seq[byte]

  try:
    bytes = Base64Url.decode(line)
  except Base64Error:
    fail("the private key is not base64url")

  let key = PrivateKey.init(bytes).valueOr:
    fail("the private key is not a libp2p private key: " & $error)

  if key.scheme != PKScheme.Secp256k1:
    fail("the private key is not a secp256k1 key")

  key

when isMainModule:
  var
    keyFile = ""
    label = ""
    cidText = ""
    seqnum = Opt.none(uint64)

  let params = commandLineParams()
  var i = 0

  while i < params.len:
    case params[i]
    of "--help", "-h":
      printHelp()
      quit(QuitSuccess)
    of "--key-file":
      keyFile = nextValue(params, i, "--key-file")
    of "--label":
      label = nextValue(params, i, "--label")
    of "--cid":
      cidText = nextValue(params, i, "--cid")
    of "--seqnum":
      seqnum = Opt.some(parseSeqnum(nextValue(params, i, "--seqnum")))
    else:
      fail("unknown argument: " & params[i] & ", see --help")

    inc i

  if keyFile.len == 0 or label.len == 0 or cidText.len == 0:
    fail("--key-file, --label and --cid are required, see --help")

  let
    cid = Cid.init(cidText).valueOr:
      fail("--cid is not a valid CID: " & $error)
    privateKey = parsePrivateKey(readKeyLine(keyFile))
    now = getTime().toUnix()
    sequence = seqnum.valueOr:
      now.uint64

  let nameRecord = NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: cid,
    seqnum: sequence,
    expiration: now + NameRecordLifetime,
  )

  let signed = sign(nameRecord, privateKey).valueOr:
    fail(error.msg)

  echo $ %*{"nameKey": nameKeyString(signed), "record": Base64Url.encode(signed.encode())}
