import pkg/results

## The connection type selected by a download, independently of node capability.
type DownloadTransport* {.pure.} = enum
  Direct
  Mix

func parseDownloadTransport*(value: string): Result[DownloadTransport, string] =
  case value
  of "direct":
    ok(DownloadTransport.Direct)
  of "mix":
    ok(DownloadTransport.Mix)
  else:
    err("transport must be 'direct' or 'mix'")
