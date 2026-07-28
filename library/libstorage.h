/**
 * libstorage.h - C-exported interface for the Storage shared library
 *
 * This file implements the public C API for libstorage. It acts as the bridge
 * between C programs and the internal Nim implementation.
 *
 * Unless it is explicitly stated otherwise, all functions are asynchronous and execute
 * their work on a separate thread, returning results via the provided callback. The
 * result code of the function represents the synchronous status of the call itself:
 * returning RET_OK if the job has been dispatched to the thread, and RET_ERR in case
 * of immediate failure.
 *
 * The callback function is invoked with the result of the operation, including
 * any data or error messages. If the call was successful, `callerRet` will be RET_OK,
 * and `msg` will contain the result data. If there was an error, `callerRet` will be RET_ERR,
 * and `msg` will contain the error message.
 *
 * When a function supports progress updates, it may invoke the callback multiple times:
 * first with RET_PROGRESS and progress information, and finally with RET_OK or RET_ERR
 * upon completion. The msg parameter will a chunk of data for upload and download operations.
 *
 * `userData` is a pointer provided by the caller that is passed back to the callback
 * for context.
 */

#ifndef __libstorage__
#define __libstorage__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// The possible returned values for the functions that return int
#define RET_OK 0
#define RET_ERR 1
#define RET_MISSING_CALLBACK 2

// RET_PROGRESS is used to indicate that the callback is being
// with progress updates.
#define RET_PROGRESS 3

#ifdef __cplusplus
extern "C"
{
#endif

    typedef void (*StorageCallback)(int callerRet, const char *msg, size_t len, void *userData);

    // Create a new instance of a Logos Storage node.
    // `configJson` is a JSON string with the configuration overwriting defaults.
    // Returns a pointer to the StorageContext used to interact with the node.
    //
    // Typical usage:
    // ctx = storage_new(configJson, myCallback, myUserData);
    // storage_start(ctx, ...);
    // ...
    // storage_stop(ctx, ...);
    // storage_destroy(ctx, ...);
    void *storage_new(
        const char *configJson,
        StorageCallback callback,
        void *userData);

    // Get the Logos Storage version as a null-terminated string, which
    // must then be freed by the caller.
    // This call does not require the node to be started and
    // does not involve a thread call.
    // It is also synchronous, so it does not require a callback.
    char *storage_version(void *ctx);

    // Get the Logos Storage contracts revision as a null-terminated
    // string, which must then be freed by the caller.
    // This call does not require the node to be started and
    // does not involve a thread call.
    // It is also synchronous, so it does not require a callback.
    char *storage_revision(void *ctx);

    // Get the repo (data-dir) used by the node.
    int storage_repo(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Retrieve debug information (JSON).
    //
    // Here is an example of the returned JSON structure:
    // {
    //  "id": "...",
    //  "addrs": ["..."],
    //  "spr": "",
    //  "table": {
    //   "localNode": "",
    //   "nodes": [
    //      {
    //       "nodeId": "...",
    //       "peerId": "...",
    //       "record": "...",
    //       "address": "...",
    //       "seen": true,
    //      }
    //   ]
    // }
    int storage_debug(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /// Get the node's  (Signed Peer Record)
    int storage_spr(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Get the node's peer ID.
    // Peer Identity reference as specified at
    // https://docs.libp2p.io/concepts/fundamentals/peers/
    int storage_peer_id(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Returns node metrics in the Logos openmetrics-compatible
    // format (https://github.com/logos-co/openmetrics-module).
    int storage_get_metrics(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Set the log level at run time.
    // `logLevel` can be one of:
    // TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL
    int storage_log_level(
        void *ctx,
        const char *logLevel,
        StorageCallback callback,
        void *userData);

    // Connect to a peer by using `peerAddresses` if provided, otherwise use `peerId`.
    // Note that the `peerId` has to be advertised in the DHT for this to work.
    int storage_connect(
        void *ctx,
        const char *peerId,
        const char **peerAddresses,
        size_t peerAddressesSize,
        StorageCallback callback,
        void *userData);

    // Request debug information for a given peer ID.
    // This api is only available if the library was compiled with
    // `storage_enable_api_debug_peers` argument.
    //
    // Here is an example of the returned JSON structure:
    // {
    //  "peerId": "...",
    //  "seqNo": 0,
    //  "addresses": [],
    // }
    int storage_peer_debug(
        void *ctx,
        const char *peerId,
        StorageCallback callback,
        void *userData);

    // Initialize an upload session for a file.
    // `filepath` for a file upload, this is the absolute path to the file
    // to be uploaded. For an upload using chunks, this is the name of the file.
    // The metadata filename and mime type are derived from this value.
    //
    // `chunkSize` defines the size of each chunk to be used during upload.
    // The default value is the default block size 1024 * 64 bytes.
    //
    // The callback returns the `sessionId` for the download session created.
    //
    // Typical usage:
    // storage_upload_init(ctx, filepath, chunkSize, myCallback, myUserData);
    // ...
    // storage_upload_chunk(ctx, sessionId, chunk, len, myCallback, myUserData);
    // ...
    // storage_upload_finalize(ctx, sessionId, myCallback, myUserData);
    int storage_upload_init(
        void *ctx,
        const char *filepath,
        size_t chunkSize,
        StorageCallback callback,
        void *userData);

    // Upload a chunk for the given `sessionId`.
    int storage_upload_chunk(
        void *ctx,
        const char *sessionId,
        const uint8_t *chunk,
        size_t len,
        StorageCallback callback,
        void *userData);

    // Finalize an upload session identified by `sessionId`.
    // The callback returns the `cid` of the uploaded content.
    int storage_upload_finalize(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    // Cancel an ongoing upload session.
    int storage_upload_cancel(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    // Upload the file defined as `filepath` in the init method.
    // The callback will be called with RET_PROGRESS updates during the upload,
    // if the chunk size is equal or greater than the session chunkSize.
    //
    // The callback returns the `cid` of the uploaded content.
    //
    // Typical usage:
    // storage_upload_init(ctx, filepath, chunkSize, myCallback, myUserData);
    // ...
    // storage_upload_file(ctx, sessionId, myCallback, myUserData);
    int storage_upload_file(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    // When set to true, runs all of the subsequent DHT **queries** over
    // the Logos mix network. Note that this affects queries only, not
    // advertisements.
    //
    // This is a **temporary** API and will likely be gone by mainnet.
    //
    // The callback returns a string containing the previous value for
    // private queries ("true" if they were enabled, or "false" otherwise).
    int storage_toggle_private_queries(
        void *ctx,
        bool enabled,
        StorageCallback callback,
        void *userData);

    // Initialize a download for `cid`.
    // `chunkSize` defines the size of each chunk to be used during download.
    // The default value is the default block size 1024 * 64 bytes.
    // `local` indicates whether to attempt local store retrieval only.
    //
    // Typical usage:
    // storage_download_init(ctx, cid, chunkSize, local, myCallback, myUserData);
    // ...
    // storage_download_stream(ctx, cid, filepath, myCallback, myUserData);
    int storage_download_init(
        void *ctx,
        const char *cid,
        size_t chunkSize,
        bool local,
        StorageCallback callback,
        void *userData);

    // Perform a streaming download for `cid`.
    // The init method must have been called prior to this.
    // If filepath is provided, the content will be written to that file.
    // The callback will be called with RET_PROGRESS updates during the download/
    // `local` indicates whether to attempt local store retrieval only.
    //
    // Typical usage:
    // storage_download_init(ctx, cid, chunkSize, local, myCallback, myUserData);
    // ...
    // storage_download_stream(ctx, cid, filepath, myCallback, myUserData);
    int storage_download_stream(
        void *ctx,
        const char *cid,
        size_t chunkSize,
        bool local,
        const char *filepath,
        StorageCallback callback,
        void *userData);

    // Download a chunk for the given `cid`.
    // The init method must have been called prior to this.
    // The chunk will be returned via the callback using `RET_PROGRESS`.
    int storage_download_chunk(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Cancel an ongoing download for `cid`.
    int storage_download_cancel(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Retrieve the manifest for the given `cid`.
    //
    // Here is an example of the returned manifest JSON structure:
    // {
    //  "treeCid": "zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX",
    //  "datasetSize": 123456,
    //  "blockSize": 65536,
    //  "filename": "example.txt",
    //  "mimetype": "text/plain",
    //  "protected": false
    // }
    int storage_download_manifest(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Retrieve the list of the manifests stored in the node.
    int storage_list(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Retrieve the storage space information.
    //
    // Here is an example of the returned JSON structure:
    // {
    //  "totalBlocks": 100000,
    //  "quotaMaxBytes": 0,
    //  "quotaUsedBytes": 0,
    //  "quotaReservedBytes": 0
    // }
    int storage_space(
        void *ctx,
        StorageCallback callback,
        void *userData);

    // Delete the content identified by `cid`.
    int storage_delete(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Fetch the content identified by `cid` from the network into
    // local store.
    // The download is done in background so the callback
    // will not receive progress updates.
    int storage_fetch(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Check if the content identified by `cid` exists in local store.
    int storage_exists(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    // Start the Logos Storage node.
    // The node can be started and stopped multiple times.
    //
    // Typical usage:
    // ctx = storage_new(configJson, myCallback, myUserData);
    // storage_start(ctx, ...);
    // ...
    // storage_stop(ctx, ...);
    // storage_destroy(ctx, ...);
    int storage_start(void *ctx,
                      StorageCallback callback,
                      void *userData);

    // Stop the Logos Storage node.
    // The node can be started and stopped multiple times.
    //
    // Typical usage:
    // ctx = storage_new(configJson, myCallback, myUserData);
    // storage_start(ctx, ...);
    // ...
    // storage_stop(ctx, ...);
    // storage_destroy(ctx, ...);
    int storage_stop(void *ctx,
                     StorageCallback callback,
                     void *userData);

    // Close the Logos Storage node.
    // Use this to release resources before destroying the node.
    //
    // Typical usage:
    // ctx = storage_new(configJson, myCallback, myUserData);
    // storage_start(ctx, ...);
    // ...
    // storage_stop(ctx, ...);
    // storage_close(ctx, ...);
    int storage_close(void *ctx,
                      StorageCallback callback,
                      void *userData);

    // Destroys an instance of a Logos Storage node.
    // This will free all resources associated with the node.
    // The node must be stopped and closed before calling this function.
    // The call is synchronous, so it does not require a callback.
    //
    // Typical usage:
    // ctx = storage_new(configJson, myCallback, myUserData);
    // storage_start(ctx, ...);
    // ...
    // storage_stop(ctx, ...);
    // storage_close(ctx, ...);
    // storage_destroy(ctx, ...);
    int storage_destroy(void *ctx);

    // Not used currently.
    // Reserved for future use to set an event callback.
    void storage_set_event_callback(void *ctx,
                                    StorageCallback callback,
                                    void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libstorage__ */
