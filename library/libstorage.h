/**
 * @file libstorage.h
 * @ingroup libstorage
 * @brief C-exported interface for the Storage shared library.
 *
 * This file implements the public C API for libstorage. It acts as the bridge
 * between C programs and the internal Nim implementation.
 *
 * Unless it is explicitly stated otherwise, all functions are asynchronous and execute
 * their work on a separate thread, returning results via the provided callback. The
 * result code of the function represents the synchronous status of the call itself:
 * returning `RET_OK` if the job has been dispatched to the thread, and `RET_ERR` in case
 * of immediate failure.
 *
 * The callback function is invoked with the result of the operation, including
 * any data or error messages. If the call was successful, `callerRet` will be `RET_OK`,
 * and `msg` will contain the result data. If there was an error, `callerRet` will be `RET_ERR`,
 * and `msg` will contain the error message.
 *
 * When a function supports progress updates, it may invoke the callback multiple times:
 * first with `RET_PROGRESS` and progress information, and finally with `RET_OK` or `RET_ERR`
 * upon completion. The `msg` parameter will contain a chunk of data for upload and
 * download operations.
 *
 * `userData` is a pointer provided by the caller that is passed back to the callback
 * for context.
 */

/**
 * @defgroup libstorage libstorage C API
 * @brief Public C API for the Storage shared library.
 *
 * Required for the doxygen > moxygen generation pipeline to render correctly.
 */

#ifndef __libstorage__
#define __libstorage__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/**
 * @defgroup return_codes Return Codes
 * @ingroup libstorage
 * @brief Standardized return values for API functions. These defines are used
 * to indicate the status of a function call:
 *   - Synchronous functions return the final state immediately.
 *   - Asynchronous functions may return RET_PROGRESS before a final state.
 */

/**
 * @addtogroup return_codes
 * @{
 */

/**
 * The call succeeded: the job has been dispatched to the worker thread
 * (asynchronous functions) or completed successfully (synchronous functions).
 */
#define RET_OK 0

/**
 * The call failed immediately.
 */
#define RET_ERR 1

/**
 * A required callback was not provided.
 */
#define RET_MISSING_CALLBACK 2

/**
 * The callback is being invoked with a progress update; a final `RET_OK`
 * or `RET_ERR` invocation follows upon completion.
 */
#define RET_PROGRESS 3

/**
 * @}
 */

#ifdef __cplusplus
extern "C"
{
#endif

    /**
     * Callback invoked with the result of an operation.
     *
     * @param callerRet `RET_OK` on success, `RET_ERR` on failure, or
     *                  `RET_PROGRESS` for an intermediate progress update.
     * @param msg       The result data on success, the error message on
     *                  failure, or a chunk of data for upload and download
     *                  progress updates.
     * @param len       Length of `msg` in bytes.
     * @param userData  The pointer provided by the caller, passed back for
     *                  context.
     */
    typedef void (*StorageCallback)(int callerRet, const char *msg, size_t len, void *userData);

    /**
     * Create a new instance of a Logos Storage node.
     *
     * Typical usage:
     * @code{.c}
     * ctx = storage_new(configJson, myCallback, myUserData);
     * storage_start(ctx, ...);
     * // ...
     * storage_stop(ctx, ...);
     * storage_destroy(ctx);
     * @endcode
     *
     * @param configJson JSON string with the configuration overwriting defaults.
     * @param callback   Invoked with the result of the operation.
     * @param userData   Caller-provided pointer passed back to `callback`.
     * @return Pointer to the `StorageContext` used to interact with the node.
     */
    void *storage_new(
        const char *configJson,
        StorageCallback callback,
        void *userData);

    /**
     * Get the Logos Storage version as a null-terminated string.
     *
     * This call does not require the node to be started and does not involve
     * a thread call. It is also synchronous, so it does not require a callback.
     *
     * @param ctx The node context returned by `storage_new`.
     * @return The version string, which must then be freed by the caller.
     */
    char *storage_version(void *ctx);

    /**
     * Get the Logos Storage contracts revision as a null-terminated string.
     *
     * This call does not require the node to be started and does not involve
     * a thread call. It is also synchronous, so it does not require a callback.
     *
     * @param ctx The node context returned by `storage_new`.
     * @return The revision string, which must then be freed by the caller.
     */
    char *storage_revision(void *ctx);

    /**
     * Get the repo (data-dir) used by the node.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the repo path.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_repo(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Retrieve debug information (JSON).
     *
     * Here is an example of the returned JSON structure:
     * @code{.json}
     * {
     *   "id": "...",
     *   "addrs": ["..."],
     *   "spr": "",
     *   "announceAddresses": ["..."],
     *   "table": {
     *     "localNode": "",
     *     "nodes": [
     *       {
     *         "nodeId": "...",
     *         "peerId": "...",
     *         "record": "...",
     *         "address": "...",
     *         "seen": true
     *       }
     *     ]
     *   }
     * }
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the debug information JSON.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_debug(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Get the node's SPR (Signed Peer Record).
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the signed peer record.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_spr(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Get the node's peer ID.
     *
     * Peer Identity reference as specified at
     * https://docs.libp2p.io/concepts/fundamentals/peers/
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the peer ID.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_peer_id(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Get node metrics in the Logos openmetrics-compatible format
     * (https://github.com/logos-co/openmetrics-module).
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the metrics data.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_get_metrics(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Set the log level at run time.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param logLevel One of `TRACE`, `DEBUG`, `INFO`, `NOTICE`, `WARN`,
     *                 `ERROR` or `FATAL`.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_log_level(
        void *ctx,
        const char *logLevel,
        StorageCallback callback,
        void *userData);

    /**
     * Connect to a peer by using `peerAddresses` if provided, otherwise use
     * `peerId`.
     *
     * @note The `peerId` has to be advertised in the DHT for this to work.
     *
     * @param ctx               The node context returned by `storage_new`.
     * @param peerId            The peer ID to connect to when no addresses
     *                          are provided.
     * @param peerAddresses     Explicit peer addresses to dial, or `NULL`.
     * @param peerAddressesSize Number of entries in `peerAddresses`.
     * @param callback          Invoked with the result of the operation.
     * @param userData          Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_connect(
        void *ctx,
        const char *peerId,
        const char **peerAddresses,
        size_t peerAddressesSize,
        StorageCallback callback,
        void *userData);

    /**
     * Request debug information for a given peer ID.
     *
     * @note This API is only available if the library was compiled with the
     * `storage_enable_api_debug_peers` argument.
     *
     * Here is an example of the returned JSON structure:
     * @code{.json}
     * {
     *   "peerId": "...",
     *   "seqNo": 0,
     *   "addresses": []
     * }
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param peerId   The peer ID to request debug information for.
     * @param callback Invoked with the peer debug information JSON.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_peer_debug(
        void *ctx,
        const char *peerId,
        StorageCallback callback,
        void *userData);

    /**
     * Initialize an upload session for a file.
     *
     * Typical usage:
     * @code{.c}
     * storage_upload_init(ctx, filepath, chunkSize, myCallback, myUserData);
     * // ...
     * storage_upload_chunk(ctx, sessionId, chunk, len, myCallback, myUserData);
     * // ...
     * storage_upload_finalize(ctx, sessionId, myCallback, myUserData);
     * @endcode
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param filepath  For a file upload, the absolute path to the file to be
     *                  uploaded. For an upload using chunks, the name of the
     *                  file. The metadata filename and mime type are derived
     *                  from this value.
     * @param chunkSize The size of each chunk to be used during upload. The
     *                  default value is the default block size 1024 * 64 bytes.
     * @param callback  Invoked with the `sessionId` for the upload session
     *                  created.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_upload_init(
        void *ctx,
        const char *filepath,
        size_t chunkSize,
        StorageCallback callback,
        void *userData);

    /**
     * Upload a chunk for the given `sessionId`.
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param sessionId The upload session returned by `storage_upload_init`.
     * @param chunk     The chunk data to upload.
     * @param len       Length of `chunk` in bytes.
     * @param callback  Invoked with the result of the operation.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_upload_chunk(
        void *ctx,
        const char *sessionId,
        const uint8_t *chunk,
        size_t len,
        StorageCallback callback,
        void *userData);

    /**
     * Finalize an upload session identified by `sessionId`.
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param sessionId The upload session returned by `storage_upload_init`.
     * @param callback  Invoked with the `cid` of the uploaded content.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_upload_finalize(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    /**
     * Cancel an ongoing upload session.
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param sessionId The upload session returned by `storage_upload_init`.
     * @param callback  Invoked with the result of the operation.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_upload_cancel(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    /**
     * Upload the file defined as `filepath` in the init method.
     *
     * The callback will be called with `RET_PROGRESS` updates during the
     * upload, if the chunk size is equal or greater than the session
     * `chunkSize`.
     *
     * Typical usage:
     * @code{.c}
     * storage_upload_init(ctx, filepath, chunkSize, myCallback, myUserData);
     * // ...
     * storage_upload_file(ctx, sessionId, myCallback, myUserData);
     * @endcode
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param sessionId The upload session returned by `storage_upload_init`.
     * @param callback  Invoked with the `cid` of the uploaded content.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_upload_file(
        void *ctx,
        const char *sessionId,
        StorageCallback callback,
        void *userData);

    /**
     * When set to true, runs all of the subsequent DHT **queries** over the
     * Logos mix network.
     *
     * @note This affects queries only, not advertisements.
     *
     * @note This is a **temporary** API and will likely be gone by mainnet.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param enabled  Whether to run subsequent DHT queries over the mix
     *                 network.
     * @param callback Invoked with a string containing the previous value for
     *                 private queries (`"true"` if they were enabled, or
     *                 `"false"` otherwise).
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_toggle_private_queries(
        void *ctx,
        bool enabled,
        StorageCallback callback,
        void *userData);

    /**
     * Initialize a download for `cid`.
     *
     * Typical usage:
     * @code{.c}
     * storage_download_init(ctx, cid, chunkSize, local, myCallback, myUserData);
     * // ...
     * storage_download_stream(ctx, cid, filepath, myCallback, myUserData);
     * @endcode
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param cid       The content identifier to download.
     * @param chunkSize The size of each chunk to be used during download. The
     *                  default value is the default block size 1024 * 64 bytes.
     * @param local     Whether to attempt local store retrieval only.
     * @param callback  Invoked with the result of the operation.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_download_init(
        void *ctx,
        const char *cid,
        size_t chunkSize,
        bool local,
        StorageCallback callback,
        void *userData);

    /**
     * Perform a streaming download for `cid`.
     *
     * The init method must have been called prior to this. The callback will
     * be called with `RET_PROGRESS` updates during the download.
     *
     * Typical usage:
     * @code{.c}
     * storage_download_init(ctx, cid, chunkSize, local, myCallback, myUserData);
     * // ...
     * storage_download_stream(ctx, cid, filepath, myCallback, myUserData);
     * @endcode
     *
     * @param ctx       The node context returned by `storage_new`.
     * @param cid       The content identifier to download.
     * @param chunkSize The size of each chunk to be used during download. The
     *                  default value is the default block size 1024 * 64 bytes.
     * @param local     Whether to attempt local store retrieval only.
     * @param filepath  If provided, the content will be written to that file.
     * @param callback  Invoked with the result of the operation.
     * @param userData  Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_download_stream(
        void *ctx,
        const char *cid,
        size_t chunkSize,
        bool local,
        const char *filepath,
        StorageCallback callback,
        void *userData);

    /**
     * Download a chunk for the given `cid`.
     *
     * The init method must have been called prior to this. The chunk will be
     * returned via the callback using `RET_PROGRESS`.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier to download.
     * @param callback Invoked with the downloaded chunk.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_download_chunk(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Cancel an ongoing download for `cid`.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier of the download to cancel.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_download_cancel(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Retrieve the manifest for the given `cid`.
     *
     * Here is an example of the returned manifest JSON structure:
     * @code{.json}
     * {
     *   "treeCid": "zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX",
     *   "datasetSize": 123456,
     *   "blockSize": 65536,
     *   "filename": "example.txt",
     *   "mimetype": "text/plain",
     *   "protected": false
     * }
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier to retrieve the manifest for.
     * @param callback Invoked with the manifest JSON.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_download_manifest(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Retrieve the list of the manifests stored in the node.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the list of manifests.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_list(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Retrieve the storage space information.
     *
     * Here is an example of the returned JSON structure:
     * @code{.json}
     * {
     *   "totalBlocks": 100000,
     *   "quotaMaxBytes": 0,
     *   "quotaUsedBytes": 0,
     *   "quotaReservedBytes": 0
     * }
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the storage space information JSON.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_space(
        void *ctx,
        StorageCallback callback,
        void *userData);

    /**
     * Delete the content identified by `cid`.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier of the content to delete.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_delete(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Fetch the content identified by `cid` from the network into local store.
     *
     * @note The download is done in background so the callback will not
     * receive progress updates.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier of the content to fetch.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_fetch(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Check if the content identified by `cid` exists in local store.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param cid      The content identifier of the content to check.
     * @param callback Invoked with the result of the check.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_exists(
        void *ctx,
        const char *cid,
        StorageCallback callback,
        void *userData);

    /**
     * Start the Logos Storage node.
     *
     * The node can be started and stopped multiple times.
     *
     * Typical usage:
     * @code{.c}
     * ctx = storage_new(configJson, myCallback, myUserData);
     * storage_start(ctx, ...);
     * // ...
     * storage_stop(ctx, ...);
     * storage_destroy(ctx);
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_start(void *ctx,
                      StorageCallback callback,
                      void *userData);

    /**
     * Stop the Logos Storage node.
     *
     * The node can be started and stopped multiple times.
     *
     * Typical usage:
     * @code{.c}
     * ctx = storage_new(configJson, myCallback, myUserData);
     * storage_start(ctx, ...);
     * // ...
     * storage_stop(ctx, ...);
     * storage_destroy(ctx);
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_stop(void *ctx,
                     StorageCallback callback,
                     void *userData);

    /**
     * Close the Logos Storage node.
     *
     * Use this to release resources before destroying the node.
     *
     * Typical usage:
     * @code{.c}
     * ctx = storage_new(configJson, myCallback, myUserData);
     * storage_start(ctx, ...);
     * // ...
     * storage_stop(ctx, ...);
     * storage_close(ctx, ...);
     * @endcode
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback Invoked with the result of the operation.
     * @param userData Caller-provided pointer passed back to `callback`.
     * @return `RET_OK` if the job was dispatched, `RET_ERR` on immediate failure.
     */
    int storage_close(void *ctx,
                      StorageCallback callback,
                      void *userData);

    /**
     * Destroys an instance of a Logos Storage node.
     *
     * This will free all resources associated with the node.
     * The call is synchronous, so it does not require a callback.
     *
     * @note The node must be stopped and closed before calling this function.
     *
     * Typical usage:
     * @code{.c}
     * ctx = storage_new(configJson, myCallback, myUserData);
     * storage_start(ctx, ...);
     * // ...
     * storage_stop(ctx, ...);
     * storage_close(ctx, ...);
     * storage_destroy(ctx);
     * @endcode
     *
     * @param ctx The node context returned by `storage_new`.
     * @return `RET_OK` on success, `RET_ERR` on failure.
     */
    int storage_destroy(void *ctx);

    /**
     * Not used currently.
     *
     * Reserved for future use to set an event callback.
     *
     * @param ctx      The node context returned by `storage_new`.
     * @param callback The event callback to set.
     * @param userData Caller-provided pointer passed back to `callback`.
     */
    void storage_set_event_callback(void *ctx,
                                    StorageCallback callback,
                                    void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libstorage__ */
