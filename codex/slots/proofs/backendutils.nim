import ./backends
import pkg/taskpools

type BackendUtils* = ref object of RootObj

method initializeCircomBackend*(
    self: BackendUtils,
    r1csFile: string,
    wasmFile: string,
    zKeyFile: string,
    taskpool: Taskpool,
): AnyBackend {.base, gcsafe.} =
  CircomCompat.init(r1csFile, wasmFile, zKeyFile, taskpool = taskpool)
