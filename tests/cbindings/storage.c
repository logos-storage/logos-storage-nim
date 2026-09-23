#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include "../../library/libstorage.h"

/* Provide realpath on Windows (not available on some MSVC/MinGW setups) */
#if defined(_WIN32) || defined(_WIN64)
#include <limits.h>
#if defined(_MSC_VER)
#include <direct.h>
#define realpath(N,R) _fullpath((R),(N),_MAX_PATH)
#else
/* MinGW / other Windows gcc: map to _fullpath using PATH_MAX */
#include <stdlib.h>
#define realpath(N,R) _fullpath((R),(N),PATH_MAX)
#endif
#endif

#define GRN "\033[0;32m"
#define RED "\033[0;31m"
#define YEL "\033[0;33m"
#define NC "\033[0m" // No Color

#define BEGIN_SUITE int passed = 0;
// RUN_TEST runs a test expression, printing the test name as it executes.
#define RUN_TEST(expr)                             \
    do                                             \
    {                                              \
        printf(YEL "[RUN] %s" NC "... ", #expr);    \
        fflush(stdout);                            \
        if ((expr) != RET_OK)                      \
        {                                          \
            fprintf(stderr, RED "[FAIL]\n" NC); \
            fprintf(stderr, RED "FAIL. Tests run: %d\n" NC, passed + 1); \
            return RET_ERR;                        \
        }                                          \
        printf(GRN "[PASS]\n" NC);               \
        passed += 1;                               \
        fflush(stdout);                            \
    } while (0)

#define END_SUITE printf(GRN "SUCCESS. Tests passed: %d\n" NC, passed + 1); \
        fflush(stdout);

// We need 250 as max retries mainly for the start function in CI.
// Other functions should be not need that many retries.
#define MAX_RETRIES 250

typedef struct
{
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool done;
    int ret;
    char *msg;
    char *chunk;
    size_t len;
} Resp;

static Resp *alloc_resp(void)
{
    Resp *r = (Resp *)calloc(1, sizeof(Resp));
    pthread_mutex_init(&r->mutex, NULL);
    pthread_cond_init(&r->cond, NULL);
    r->done = false;
    r->msg = NULL;
    r->chunk = NULL;
    r->ret = -1;
    return r;
}

static void free_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    if (r->msg)
    {
        free(r->msg);
    }

    if (r->chunk)
    {
        free(r->chunk);
    }

    pthread_cond_destroy(&r->cond);
    pthread_mutex_destroy(&r->mutex);
    free(r);
}

static int get_ret(Resp *r)
{
    if (!r)
    {
        return RET_ERR;
    }

    pthread_mutex_lock(&r->mutex);
    int ret = r->ret;
    pthread_mutex_unlock(&r->mutex);

    return ret;
}

// wait_resp waits until the async response is ready or max retries is reached.
// The resp is initially set to -1, to any code (RET_OK, RET_ERR, RET_PROGRESS) will
// indicate that the response is ready to be consumed.
static void wait_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    const long timeout_ms = MAX_RETRIES * 100;
    struct timespec deadline;

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000)
    {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000;
    }

    pthread_mutex_lock(&r->mutex);
    while (!r->done)
    {
        int rc = pthread_cond_timedwait(&r->cond, &r->mutex, &deadline);
        if (rc == ETIMEDOUT)
        {
            break;
        }
    }
    pthread_mutex_unlock(&r->mutex);
}

// is_resp_ok checks if the async response indicates success.
// It will wait first for the response to be ready.
// Then it will copy the message or chunk to res if provided.
static int is_resp_ok(Resp *r, char **res)
{
    if (!r)
    {
        return RET_ERR;
    }

    wait_resp(r);

    pthread_mutex_lock(&r->mutex);

    int ret = (r->ret == RET_OK) ? RET_OK : RET_ERR;

    // If a response pointer is provided, it’s safe to initialize it to NULL.
    if (res)
    {
        *res = NULL;
    }

    // If the response contains a chunk (for a download or an upload with RET_PROGRESS),
    // the response will be in chunk.
    // Otherwise, the response will be in msg.
    if (res && r->chunk)
    {
        *res = strdup(r->chunk);
    }
    else if (res && r->msg)
    {
        *res = strdup(r->msg);
    }

    pthread_mutex_unlock(&r->mutex);

    free_resp(r);

    return ret;
}

// callback is the function that will be called by the storage library
// when an async operation is completed or has progress to report.
// - ret is the return code of the callback
// - msg is the data returned by the callback: it can be a string or a chunk
// - len is the size of that data
// - userData is the bridge between the caller and the lib.
//   The caller passes this userData to the library.
//   When the library invokes the callback, it passes the same userData back. The callback
//   then fills it with the received information (return code, message). Once the callback
//   has completed, the caller can read the populated userData.
static void callback(int ret, const char *msg, size_t len, void *userData)
{
    Resp *r = (Resp *)userData;

    // This means that the caller did not provide a valid userData pointer.
    // In that case, we have nothing to do but return.
    if (!r)
    {
        return;
    }

    pthread_mutex_lock(&r->mutex);

    // If the reponse already has a message, just free it first.
    if (r->msg)
    {
        free(r->msg);
        r->msg = NULL;
        r->len = 0;
    }

    // For a RET_PROGRESS with chunk, copy the chunk data directly.
    // This is used for upload/download chunk progress.
    if (ret == RET_PROGRESS && msg && len > 0 && r->chunk)
    {
        memcpy(r->chunk, msg, len);
        r->len = len;
    }

    // For terminal responses, copy the message data.
    if (ret != RET_PROGRESS && msg && len > 0)
    {
        // Allocate memory for the message plus null terminator.
        r->msg = (char *)malloc(len + 1);

        // Just in case malloc fails.
        if (!r->msg)
        {
            r->len = 0;
            r->ret = RET_ERR;
            r->done = true;
            pthread_cond_signal(&r->cond);
            pthread_mutex_unlock(&r->mutex);
            return;
        }

        memcpy(r->msg, msg, len);

        // Null terminate is needed here otherwise
        // the msg will contains non valid string like "0� :g"
        r->msg[len] = '\0';

        r->len = len;
    }
    else if (ret != RET_PROGRESS)
    {
        r->msg = NULL;
        r->len = 0;
    }

    // Progress updates are intermediate callbacks. Keep any copied chunk data,
    // but wait for the final RET_OK/RET_ERR before completing the response.
    if (ret == RET_PROGRESS)
    {
        pthread_mutex_unlock(&r->mutex);
        return;
    }

    // Publish completion last so wait_resp can only observe a fully written Resp.
    r->ret = ret;
    r->done = true;
    pthread_cond_signal(&r->cond);
    pthread_mutex_unlock(&r->mutex);
}

static int read_file(const char *filepath, char **res)
{
    FILE *file;
    char c;
    // Just read first 100 bytes for the test
    char content[100];

    file = fopen(filepath, "r");

    if (file == NULL)
    {
        return RET_ERR;
    }

    fgets(content, 100, file);

    *res = strdup(content);

    fclose(file);

    return RET_OK;
}

int setup(void **storage_ctx)
{
    // Initialize Nim runtime
    extern void libstorageNimMain(void);
    libstorageNimMain();

    Resp *r = alloc_resp();
    const char *cfg = "{\"log-level\":\"WARN\",\"data-dir\":\"./data-dir\"}";
    void *ctx = storage_new(cfg, (StorageCallback)callback, r);

    if (!ctx)
    {
        free_resp(r);
        return RET_ERR;
    }

    wait_resp(r);

    if (get_ret(r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    (*storage_ctx) = ctx;

    free_resp(r);

    return RET_OK;
}

int start(void *storage_ctx)
{
    Resp *r = alloc_resp();

    if (storage_start(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int cleanup(void *storage_ctx)
{
    Resp *r = alloc_resp();

    // Stop node
    if (storage_stop(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    // Close node
    if (storage_close(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    // Destroy node
    // No need to wait here as storage_destroy is synchronous
    if (storage_destroy(storage_ctx) != RET_OK)
    {
        return RET_ERR;
    }

    return RET_OK;
}

int check_version(void *storage_ctx)
{
    char *version = storage_version(storage_ctx);
    printf("version: %s\n", version);
    free(version);
    return RET_OK;
}

int check_repo(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_repo(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strcmp(res, "./data-dir") != 0)
    {
        printf("repo mismatch: %s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_debug(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_debug(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    // Simple check to ensure the response contains spr
    if (res == NULL || strstr(res, "spr") == NULL)
    {
        fprintf(stderr, "debug content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_spr(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_spr(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strstr(res, "spr") == NULL)
    {
        fprintf(stderr, "spr content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_peer_id(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_peer_id(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, &res);
}

int update_log_level(void *storage_ctx, const char *log_level)
{
    char *res = NULL;

    Resp *r = alloc_resp();

    if (storage_log_level(storage_ctx, log_level, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_upload_chunk(void *storage_ctx, const char *filepath)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    char *session_id = NULL;
    const char *payload = "hello world";
    size_t chunk_size = strlen(payload);

    if (storage_upload_init(storage_ctx, filepath, chunk_size, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    uint8_t *chunk = malloc(chunk_size);
    if (!chunk)
    {
        free(session_id);
        return RET_ERR;
    }
    memcpy(chunk, payload, chunk_size);

    r = alloc_resp();

    if (storage_upload_chunk(storage_ctx, session_id, chunk, chunk_size, (StorageCallback)callback, r) != RET_OK)
    {
        free(session_id);
        free_resp(r);
        free(chunk);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        free(session_id);
        free(chunk);
        return RET_ERR;
    }

    free(chunk);
    r = alloc_resp();

    if (storage_upload_finalize(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strlen(res) == 0)
    {
        fprintf(stderr, "CID is missing\n");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int upload_cancel(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    size_t chunk_size = 64 * 1024;

    if (storage_upload_init(storage_ctx, "hello.txt", chunk_size, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_upload_cancel(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    return is_resp_ok(r, NULL);
}

int check_upload_file(void *storage_ctx, const char *filepath, char **res)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    size_t chunk_size = 64 * 1024;

    if (storage_upload_init(storage_ctx, filepath, chunk_size, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_upload_file(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    int ret = is_resp_ok(r, res);

    if (res == NULL || *res == NULL || strlen(*res) == 0)
    {
        fprintf(stderr, "CID is missing\n");
        return RET_ERR;
    }

    return ret;
}

int check_download_stream(void *storage_ctx, const char *cid, const char *filepath)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    size_t chunk_size = 64 * 1024;
    bool local = true;

    if (storage_download_init(storage_ctx, cid, chunk_size, local, false, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();
    r->chunk = malloc(chunk_size + 1);

    if (storage_download_stream(storage_ctx, cid, chunk_size, filepath, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    if (read_file("downloaded_hello.txt", &res) != RET_OK)
    {
        fprintf(stderr, "read downloaded file failed\n");
        ret = RET_ERR;
    }

    if (res == NULL || strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_download_chunk(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    size_t chunk_size = 64 * 1024;
    bool local = true;

    if (storage_download_init(storage_ctx, cid, chunk_size, local, false, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();
    r->chunk = malloc(chunk_size + 1);

    if (storage_download_chunk(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded chunk content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_download_cancel(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_download_cancel(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_download_manifest(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_download_manifest(storage_ctx, cid, false, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    const char *expected_manifest = "{\"manifestVersion\":0,\"treeCid\":\"zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX\",\"blockSize\":65536,\"datasetSize\":12,\"filename\":\"hello_world.txt\",\"mimetype\":\"text/plain\"}";

    if (res == NULL || strncmp(res, expected_manifest, strlen(expected_manifest)) != 0)
    {
        fprintf(stderr, "downloaded manifest content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

static int check_error(Resp *r, const char *expected_error)
{
    char *res = NULL;
    int ret = is_resp_ok(r, &res);
    if (ret != RET_ERR)
    {
        fprintf(stderr, "Expected RET_ERR but got %d\n", ret);
        free(res);
        return RET_ERR;
    }

    if (res == NULL || strstr(res, expected_error) == NULL)
    {
        fprintf(stderr, "Unexpected error message: %s\n", res ? res : "(null)");
        free(res);
        return RET_ERR;
    }

    free(res);
    return RET_OK;
}

int check_download_manifest_private(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_download_manifest(storage_ctx, cid, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    // This node has no Mix transport, so a private request must fail.
    return check_error(r, "Mix transport is not enabled");
}

int check_download_init_private(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_download_init(storage_ctx, cid, 0, false, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return check_error(r, "Mix transport is not enabled");
}

int check_download_privacy_mismatch(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_download_init(storage_ctx, cid, 0, false, false, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }
    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    // Reusing a direct session must not silently accept a private request.
    r = alloc_resp();
    if (storage_download_init(storage_ctx, cid, 0, false, true, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }
    if (check_error(r, "Download privacy setting does not match") != RET_OK)
    {
        return RET_ERR;
    }

    return check_download_cancel(storage_ctx, cid);
}

int check_list(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_list(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    const char *expected_manifest = "{\"manifestVersion\":0,\"treeCid\":\"zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX\",\"blockSize\":65536,\"datasetSize\":12,\"filename\":\"hello_world.txt\",\"mimetype\":\"text/plain\"}";

    if (res == NULL || strstr(res, expected_manifest) == NULL)
    {
        fprintf(stderr, "downloaded manifest content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_space(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_space(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    // Simple check to ensure the response contains totalBlocks
    if (res == NULL || strstr(res, "totalBlocks") == NULL)
    {
        fprintf(stderr, "space content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_exists(void *storage_ctx, const char *cid, bool expected)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_exists(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (expected)
    {
        if (res == NULL || strcmp(res, "true") != 0)
        {
            fprintf(stderr, "exists content mismatch, res:%s\n", res ? res : "(null)");
            ret = RET_ERR;
        }
    }
    else
    {
        if (res == NULL || strcmp(res, "false") != 0)
        {
            fprintf(stderr, "exists content mismatch, res:%s\n", res ? res : "(null)");
            ret = RET_ERR;
        }
    }

    free(res);

    return ret;
}

int check_advertise(void *storage_ctx, const char *cid, bool advertise)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_set_advertise(storage_ctx, cid, advertise, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_get_advertise(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);
    const char *expected = advertise ? "true" : "false";

    if (res == NULL || strcmp(res, expected) != 0)
    {
        fprintf(stderr, "advertise content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_delete(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_delete(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_get_metrics(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_get_metrics(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);
    if (ret != RET_OK)
    {
        free(res);
        return ret;
    }

    // Checks that response contains a metric we are SURE must exist
    if (res == NULL || strstr(res, "logos_storage_libp2p_successful_dials_total") == NULL)
    {
        fprintf(stderr, "get_metrics missing expected metric\n");
        free(res);
        return RET_ERR;
    }

    free(res);
    return RET_OK;
}

// TODO: implement check_fetch
// It is a bit complicated because it requires two nodes
// connected together to fetch from peers.
// A good idea would be to use connect function using addresses.
// This test will be quite important when the block engine is re-implemented.
int check_fetch(void *storage_ctx, const char *cid)
{
    return RET_OK;
}

int main(void)
{
    void *storage_ctx = NULL;
    char *res = NULL;
    char *cid = NULL;

    BEGIN_SUITE

    RUN_TEST(setup(&storage_ctx));
    RUN_TEST(check_version(storage_ctx));
    RUN_TEST(start(storage_ctx));
    RUN_TEST(check_repo(storage_ctx));
    RUN_TEST(check_debug(storage_ctx));
    RUN_TEST(check_spr(storage_ctx));
    RUN_TEST(check_peer_id(storage_ctx));
    RUN_TEST(check_upload_chunk(storage_ctx, "hello_world.txt"));
    RUN_TEST(upload_cancel(storage_ctx));

    char *path = realpath("hello_world.txt", NULL);
    if (!path)
    {
        fprintf(stderr, "realpath failed\n");
        return RET_ERR;
    }

    RUN_TEST(check_upload_file(storage_ctx, path, &cid));

    free(path);

    RUN_TEST(check_download_stream(storage_ctx, cid, "downloaded_hello.txt"));
    RUN_TEST(check_download_chunk(storage_ctx, cid));
    RUN_TEST(check_download_cancel(storage_ctx, cid));
    RUN_TEST(check_download_manifest(storage_ctx, cid));
    RUN_TEST(check_download_manifest_private(storage_ctx, cid));
    RUN_TEST(check_download_init_private(storage_ctx, cid));
    RUN_TEST(check_download_privacy_mismatch(storage_ctx, cid));
    RUN_TEST(check_list(storage_ctx));
    RUN_TEST(check_space(storage_ctx));
    RUN_TEST(check_exists(storage_ctx, cid, true));
    RUN_TEST(check_advertise(storage_ctx, cid, false));
    RUN_TEST(check_advertise(storage_ctx, cid, true));
    RUN_TEST(check_delete(storage_ctx, cid));
    RUN_TEST(check_exists(storage_ctx, cid, false));

    free(cid);

    RUN_TEST(update_log_level(storage_ctx, "TRACE"));
    RUN_TEST(check_get_metrics(storage_ctx));
    RUN_TEST(cleanup(storage_ctx));

    END_SUITE
}
