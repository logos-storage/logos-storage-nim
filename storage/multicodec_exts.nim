# Keep the default registration's CodecExts local to this block so we can
# combine it with Storage's codecs without duplicating MixTransport's value.
const MixTransportCodecExts = block:
  includeFile "../vendor/libp2p-mix-transport/libp2p_mix_transport/address/defaults/multicodec.nim"
  CodecExts

const CodecExts =
  @[("storage-manifest", 0xCD01), ("storage-block", 0xCD02), ("storage-root", 0xCD03)] &
  @MixTransportCodecExts
