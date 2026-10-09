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

// The node start can be slow in CI, so the wait is generous.
#define TIMEOUT_MS 25000

typedef struct
{
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool done;
    int ret;
    char *msg;
    StorageCtx *ctx;
} Resp;

static Resp *alloc_resp(void)
{
    Resp *r = (Resp *)calloc(1, sizeof(Resp));
    pthread_mutex_init(&r->mutex, NULL);
    pthread_cond_init(&r->cond, NULL);
    r->ret = -1;
    return r;
}

static void free_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    free(r->msg);
    pthread_cond_destroy(&r->cond);
    pthread_mutex_destroy(&r->mutex);
    free(r);
}

// The caller holds r->mutex.
static void publish(Resp *r, int ret)
{
    r->ret = ret;
    r->done = true;
    pthread_cond_signal(&r->cond);
}

static char *dup_n(const char *data, size_t len)
{
    char *out = (char *)malloc(len + 1);

    if (!out)
    {
        return NULL;
    }

    if (len > 0)
    {
        memcpy(out, data, len);
    }

    out[len] = '\0';

    return out;
}

static struct timespec timeout_deadline(void)
{
    struct timespec deadline;

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += TIMEOUT_MS / 1000;
    deadline.tv_nsec += (TIMEOUT_MS % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000)
    {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000;
    }

    return deadline;
}

static void wait_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    struct timespec deadline = timeout_deadline();

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

// is_resp_ok waits for the reply, hands the payload over in res and frees the Resp.
static int is_resp_ok(Resp *r, char **res)
{
    if (!r)
    {
        return RET_ERR;
    }

    wait_resp(r);

    pthread_mutex_lock(&r->mutex);

    int ret = (r->ret == RET_OK) ? RET_OK : RET_ERR;

    if (res)
    {
        *res = r->msg;
        r->msg = NULL;
    }

    pthread_mutex_unlock(&r->mutex);

    free_resp(r);

    return ret;
}

// Every Result[string, string] reply typedef shares this signature.
static void on_str_reply(int err_code, const NimFfiStr *reply, const char *err_msg, void *user_data)
{
    Resp *r = (Resp *)user_data;

    if (!r)
    {
        return;
    }

    pthread_mutex_lock(&r->mutex);

    free(r->msg);
    r->msg = NULL;

    if (err_code == RET_OK && reply)
    {
        r->msg = dup_n(reply->data ? reply->data : "", reply->len);
    }
    else if (err_msg)
    {
        r->msg = strdup(err_msg);
    }

    publish(r, err_code);
    pthread_mutex_unlock(&r->mutex);
}

static void on_bytes_reply(int err_code, const NimFfiBytes *reply, const char *err_msg, void *user_data)
{
    Resp *r = (Resp *)user_data;

    if (!r)
    {
        return;
    }

    pthread_mutex_lock(&r->mutex);

    free(r->msg);
    r->msg = NULL;

    if (err_code == RET_OK && reply)
    {
        r->msg = dup_n((const char *)reply->data, reply->len);
    }
    else if (err_msg)
    {
        r->msg = strdup(err_msg);
    }

    publish(r, err_code);
    pthread_mutex_unlock(&r->mutex);
}

static void on_created(int err_code, StorageCtx *ctx, const char *err_msg, void *user_data)
{
    Resp *r = (Resp *)user_data;

    if (!r)
    {
        return;
    }

    pthread_mutex_lock(&r->mutex);

    r->ctx = ctx;

    if (err_code != RET_OK && err_msg)
    {
        r->msg = strdup(err_msg);
    }

    publish(r, err_code);
    pthread_mutex_unlock(&r->mutex);
}

// Events arrive on the event thread, which can lag behind the reply callback.
static pthread_mutex_t events_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t events_cond = PTHREAD_COND_INITIALIZER;
static char chunks[4096];
static size_t chunks_len;
static int upload_progress_count;

static void reset_chunks(void)
{
    pthread_mutex_lock(&events_mutex);
    chunks_len = 0;
    chunks[0] = '\0';
    pthread_mutex_unlock(&events_mutex);
}

static bool upload_progress_seen(void)
{
    return upload_progress_count > 0;
}

static bool hello_world_streamed(void)
{
    return chunks_len >= strlen("Hello World!");
}

// The caller holds events_mutex.
static void wait_events(bool (*ready)(void))
{
    struct timespec deadline = timeout_deadline();

    while (!ready())
    {
        if (pthread_cond_timedwait(&events_cond, &events_mutex, &deadline) == ETIMEDOUT)
        {
            break;
        }
    }
}

static void on_download_chunk(const OnDownloadChunkPayload *evt, void *user_data)
{
    if (!evt)
    {
        return;
    }

    pthread_mutex_lock(&events_mutex);

    size_t room = sizeof(chunks) - 1 - chunks_len;
    size_t n = evt->data.len < room ? evt->data.len : room;

    memcpy(chunks + chunks_len, evt->data.data, n);
    chunks_len += n;
    chunks[chunks_len] = '\0';

    pthread_cond_broadcast(&events_cond);
    pthread_mutex_unlock(&events_mutex);
}

static void on_upload_progress(const OnUploadProgressPayload *evt, void *user_data)
{
    pthread_mutex_lock(&events_mutex);
    upload_progress_count += 1;
    pthread_cond_broadcast(&events_cond);
    pthread_mutex_unlock(&events_mutex);
}

static int read_file(const char *filepath, char **res)
{
    FILE *file;
    // Just read first 100 bytes for the test
    char content[100];

    file = fopen(filepath, "r");

    if (file == NULL)
    {
        return RET_ERR;
    }

    if (fgets(content, 100, file) == NULL)
    {
        fclose(file);
        return RET_ERR;
    }

    *res = strdup(content);

    fclose(file);

    return RET_OK;
}

static StorageCtx *create_ctx(const char *cfg)
{
    Resp *r = alloc_resp();

    storage_ctx_create(nimffi_str(cfg), on_created, r);

    wait_resp(r);

    pthread_mutex_lock(&r->mutex);
    StorageCtx *ctx = r->ret == RET_OK ? r->ctx : NULL;
    pthread_mutex_unlock(&r->mutex);

    if (!ctx)
    {
        fprintf(stderr, "create failed: %s\n", r->msg ? r->msg : "(null)");
    }

    free_resp(r);

    return ctx;
}

int setup(StorageCtx **storage_ctx)
{
    const char *cfg = "{\"log-level\":\"WARN\",\"data-dir\":\"./data-dir\",\"no-bootstrap-node\":true,\"nat\":\"extip:127.0.0.1\"}";
    StorageCtx *ctx = create_ctx(cfg);

    if (!ctx)
    {
        return RET_ERR;
    }

    (*storage_ctx) = ctx;

    if (storage_ctx_add_on_download_chunk_listener(ctx, on_download_chunk, NULL) == 0)
    {
        return RET_ERR;
    }

    if (storage_ctx_add_on_upload_progress_listener(ctx, on_upload_progress, NULL) == 0)
    {
        return RET_ERR;
    }

    return RET_OK;
}

int start(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();

    if (storage_ctx_start(storage_ctx, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int cleanup(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();

    if (storage_ctx_stop(storage_ctx, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    // Destroy closes the node and joins the FFI thread pair, so it is synchronous.
    return storage_ctx_destroy(storage_ctx);
}

int check_version(void)
{
    const char *version = storage_version();

    if (!version || strlen(version) == 0)
    {
        fprintf(stderr, "version is missing\n");
        return RET_ERR;
    }

    printf("version: %s\n", version);

    return RET_OK;
}

int check_repo(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_repo(storage_ctx, on_str_reply, r) != RET_OK)
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

int check_debug(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_debug(storage_ctx, on_str_reply, r) != RET_OK)
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

int check_spr(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_spr(storage_ctx, on_str_reply, r) != RET_OK)
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

int check_peer_id(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();

    if (storage_ctx_peer_id(storage_ctx, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_network(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_network(storage_ctx, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strlen(res) == 0)
    {
        fprintf(stderr, "network is missing\n");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int update_log_level(StorageCtx *storage_ctx, const char *log_level)
{
    Resp *r = alloc_resp();

    if (storage_ctx_log_level(storage_ctx, nimffi_str(log_level), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_upload_chunk(StorageCtx *storage_ctx, const char *filepath)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    char *session_id = NULL;
    const char *payload = "hello world";
    NimFfiBytes chunk = {.data = (uint8_t *)payload, .len = strlen(payload)};

    if (storage_ctx_upload_init(storage_ctx, nimffi_str(filepath), chunk.len, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        free(session_id);
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_upload_chunk(storage_ctx, nimffi_str(session_id), &chunk, on_str_reply, r) != RET_OK)
    {
        free(session_id);
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        free(session_id);
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_upload_finalize(storage_ctx, nimffi_str(session_id), on_str_reply, r) != RET_OK)
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

int upload_cancel(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    uint64_t chunk_size = 64 * 1024;

    if (storage_ctx_upload_init(storage_ctx, nimffi_str("hello.txt"), chunk_size, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        free(session_id);
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_upload_cancel(storage_ctx, nimffi_str(session_id), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    return is_resp_ok(r, NULL);
}

int check_upload_file(StorageCtx *storage_ctx, const char *filepath, char **res)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    uint64_t chunk_size = 64 * 1024;

    if (storage_ctx_upload_init(storage_ctx, nimffi_str(filepath), chunk_size, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        free(session_id);
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_upload_file(storage_ctx, nimffi_str(session_id), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    int ret = is_resp_ok(r, res);

    if (*res == NULL || strlen(*res) == 0)
    {
        fprintf(stderr, "CID is missing\n");
        return RET_ERR;
    }

    pthread_mutex_lock(&events_mutex);
    wait_events(upload_progress_seen);
    if (upload_progress_count == 0)
    {
        fprintf(stderr, "on_upload_progress never fired\n");
        ret = RET_ERR;
    }
    pthread_mutex_unlock(&events_mutex);

    return ret;
}

int download_init(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    uint64_t chunk_size = 64 * 1024;

    if (storage_ctx_download_init(storage_ctx, nimffi_str(cid), chunk_size, true, false, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_download_stream(StorageCtx *storage_ctx, const char *cid, const char *filepath)
{
    char *res = NULL;
    uint64_t chunk_size = 64 * 1024;

    if (download_init(storage_ctx, cid) != RET_OK)
    {
        return RET_ERR;
    }

    reset_chunks();

    Resp *r = alloc_resp();

    if (storage_ctx_download_stream(storage_ctx, nimffi_str(cid), chunk_size,
                                    nimffi_str(filepath), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, NULL);

    pthread_mutex_lock(&events_mutex);
    wait_events(hello_world_streamed);
    if (strncmp(chunks, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "streamed content mismatch, res:%s\n", chunks);
        ret = RET_ERR;
    }
    pthread_mutex_unlock(&events_mutex);

    if (read_file(filepath, &res) != RET_OK)
    {
        fprintf(stderr, "read downloaded file failed\n");
        return RET_ERR;
    }

    if (res == NULL || strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_download_chunk(StorageCtx *storage_ctx, const char *cid)
{
    char *res = NULL;

    if (download_init(storage_ctx, cid) != RET_OK)
    {
        return RET_ERR;
    }

    Resp *r = alloc_resp();

    if (storage_ctx_download_chunk(storage_ctx, nimffi_str(cid), on_bytes_reply, r) != RET_OK)
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

int check_download_cancel(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_ctx_download_cancel(storage_ctx, nimffi_str(cid), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_download_manifest(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_download_manifest(storage_ctx, nimffi_str(cid), false, true, on_str_reply, r) != RET_OK)
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

int check_download_manifest_private(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_ctx_download_manifest(storage_ctx, nimffi_str(cid), true, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    // This node has no Mix transport, so a private request must fail.
    return check_error(r, "Mix transport is not enabled");
}

int check_download_init_private(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_ctx_download_init(storage_ctx, nimffi_str(cid), 0, false, true, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return check_error(r, "Mix transport is not enabled");
}

int check_download_privacy_mismatch(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_ctx_download_init(storage_ctx, nimffi_str(cid), 0, false, false, true, on_str_reply, r) != RET_OK)
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
    if (storage_ctx_download_init(storage_ctx, nimffi_str(cid), 0, false, true, true, on_str_reply, r) != RET_OK)
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

int check_list(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_list(storage_ctx, on_str_reply, r) != RET_OK)
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

int check_space(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_space(storage_ctx, on_str_reply, r) != RET_OK)
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

int check_exists(StorageCtx *storage_ctx, const char *cid, bool expected)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_exists(storage_ctx, nimffi_str(cid), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);
    const char *want = expected ? "true" : "false";

    if (res == NULL || strcmp(res, want) != 0)
    {
        fprintf(stderr, "exists content mismatch, res:%s\n", res ? res : "(null)");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_advertise(StorageCtx *storage_ctx, const char *cid, bool advertise)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_set_advertise(storage_ctx, nimffi_str(cid), advertise, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_get_advertise(storage_ctx, nimffi_str(cid), on_str_reply, r) != RET_OK)
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

int check_delete(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_ctx_delete(storage_ctx, nimffi_str(cid), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_get_metrics(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_ctx_get_metrics(storage_ctx, on_str_reply, r) != RET_OK)
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

static int read_whole_file(const char *filepath, char **res)
{
    FILE *file = fopen(filepath, "rb");

    if (file == NULL || fseek(file, 0, SEEK_END) != 0)
    {
        if (file)
        {
            fclose(file);
        }
        return RET_ERR;
    }

    long size = ftell(file);
    rewind(file);
    *res = (char *)calloc(1, size > 0 ? size + 1 : 1);

    if (size < 0 || !*res || fread(*res, 1, size, file) != (size_t)size)
    {
        fclose(file);
        return RET_ERR;
    }

    fclose(file);

    return RET_OK;
}

// Uploading many blocks makes the FFI thread's GC run a full collection;
// the log file must keep receiving lines after it, through stop and destroy.
int check_log_file_after_many_blocks(void)
{
    const char *log_path = "log-file.log";
    const char *input_path = "log-file.bin";
    const char *cfg = "{\"log-level\":\"INFO\",\"log-format\":\"none\","
                      "\"log-file\":\"log-file.log\",\"data-dir\":\"./log-file-data-dir\","
                      "\"listen-ip\":\"127.0.0.1\",\"nat\":\"extip:127.0.0.1\","
                      "\"no-bootstrap-node\":true}";
    uint64_t chunk_size = 1024;
    char *cid = NULL;
    char *log = NULL;

    // 16384 blocks of zeros.
    FILE *input = fopen(input_path, "wb");
    if (!input || fseek(input, 16 * 1024 * 1024 - 1, SEEK_SET) != 0 || fputc(0, input) == EOF)
    {
        if (input)
        {
            fclose(input);
        }
        return RET_ERR;
    }
    fclose(input);

    StorageCtx *ctx = create_ctx(cfg);

    if (!ctx || start(ctx) != RET_OK)
    {
        return RET_ERR;
    }

    char *path = realpath(input_path, NULL);
    char *session_id = NULL;
    Resp *r = alloc_resp();

    if (!path || storage_ctx_upload_init(ctx, nimffi_str(path), chunk_size, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        free(path);
        return RET_ERR;
    }

    free(path);

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        free(session_id);
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_ctx_upload_file(ctx, nimffi_str(session_id), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    if (is_resp_ok(r, &cid) != RET_OK || cleanup(ctx) != RET_OK)
    {
        free(cid);
        return RET_ERR;
    }

    free(cid);
    remove(input_path);

    int ret = read_whole_file(log_path, &log);

    if (ret != RET_OK || !strstr(log, "Stored data") || !strstr(log, "Stopping Storage node"))
    {
        fprintf(stderr, "log file is missing lines, log:\n%s\n", log ? log : "(null)");
        ret = RET_ERR;
    }

    free(log);

    return ret;
}

int main(void)
{
    StorageCtx *storage_ctx = NULL;
    char *cid = NULL;

    BEGIN_SUITE

    RUN_TEST(check_version());
    RUN_TEST(setup(&storage_ctx));
    RUN_TEST(start(storage_ctx));
    RUN_TEST(check_repo(storage_ctx));
    RUN_TEST(check_debug(storage_ctx));
    RUN_TEST(check_spr(storage_ctx));
    RUN_TEST(check_peer_id(storage_ctx));
    RUN_TEST(check_network(storage_ctx));
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
    RUN_TEST(check_log_file_after_many_blocks());

    END_SUITE
}
