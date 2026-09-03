from pkg/libp2p import Cid, PeerId, MultiAddress, AddressInfo, init, `$`
import pkg/contractabi
import pkg/libp2p_mix/curve25519
import pkg/serde/json
import pkg/stew/byteutils
import pkg/questionable/results
import ../errors

export json

proc fromJson*(_: type Cid, json: JsonNode): ?!Cid =
  expectJsonKind(Cid, JString, json)
  Cid.init(json.str).mapFailure

func `%`*(cid: Cid): JsonNode =
  % $cid

func `%`*(obj: PeerId): JsonNode =
  % $obj

func `%`*(obj: AddressInfo): JsonNode =
  % $obj.address

func `%`*(obj: MultiAddress): JsonNode =
  % $obj

func `%`*(obj: FieldElement): JsonNode =
  %byteutils.toHex(fieldElementToBytes(obj))
