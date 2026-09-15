import ffi
import ./declare_lib
import ./events
import ./storage_api/upload_api
import ./storage_api/download_api
import ./storage_api/lifecycle_api
import ./storage_api/info_api
import ./storage_api/debug_api
import ./storage_api/p2p_api
import ./storage_api/data_api
import ./storage_api/mix_api

{.warning[UnusedImport]: off.}

# Reads the compile-time registries the pragmas above filled, so it stays last.
genBindings()
