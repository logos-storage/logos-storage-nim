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

// publish stores the outcome and wakes the caller. The mutex must be held.
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

static void wait_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    struct timespec deadline;

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += TIMEOUT_MS / 1000;
    deadline.tv_nsec += (TIMEOUT_MS % 1000) * 1000000;
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

// on_bytes_reply serves storage_download_chunk, which answers Result[seq[byte], string].
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

// Downloaded chunks arrive on the event thread, so the accumulator has its own lock.
static pthread_mutex_t chunks_mutex = PTHREAD_MUTEX_INITIALIZER;
static char chunks[4096];
static size_t chunks_len;
static int upload_progress_count;

static void reset_chunks(void)
{
    pthread_mutex_lock(&chunks_mutex);
    chunks_len = 0;
    chunks[0] = '\0';
    pthread_mutex_unlock(&chunks_mutex);
}

static void on_download_chunk(const OnDownloadChunkPayload *evt, void *user_data)
{
    if (!evt)
    {
        return;
    }

    pthread_mutex_lock(&chunks_mutex);

    size_t room = sizeof(chunks) - 1 - chunks_len;
    size_t n = evt->data.len < room ? evt->data.len : room;

    memcpy(chunks + chunks_len, evt->data.data, n);
    chunks_len += n;
    chunks[chunks_len] = '\0';

    pthread_mutex_unlock(&chunks_mutex);
}

static void on_upload_progress(const OnUploadProgressPayload *evt, void *user_data)
{
    pthread_mutex_lock(&chunks_mutex);
    upload_progress_count += 1;
    pthread_mutex_unlock(&chunks_mutex);
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

int setup(StorageCtx **storage_ctx)
{
    Resp *r = alloc_resp();
    const char *cfg = "{\"log-level\":\"WARN\",\"data-dir\":\"./data-dir\"}";

    storage_ctx_create(nimffi_str(cfg), on_created, r);

    wait_resp(r);

    if (r->ret != RET_OK || !r->ctx)
    {
        fprintf(stderr, "create failed: %s\n", r->msg ? r->msg : "(null)");
        free_resp(r);
        return RET_ERR;
    }

    (*storage_ctx) = r->ctx;

    if (storage_ctx_add_on_download_chunk_listener(r->ctx, on_download_chunk, NULL) == 0)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (storage_ctx_add_on_upload_progress_listener(r->ctx, on_upload_progress, NULL) == 0)
    {
        free_resp(r);
        return RET_ERR;
    }

    free_resp(r);

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
    NimFfiBytes chunk;

    chunk.data = (uint8_t *)payload;
    chunk.len = strlen(payload);

    if (storage_ctx_upload_init(storage_ctx, nimffi_str(filepath), chunk.len, on_str_reply, r) != RET_OK)
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

    if (storage_ctx_upload_init(storage_ctx, nimffi_str("hello.txt"), chunk_size, on_str_reply, r) != RET_OK)
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

    if (storage_ctx_upload_init(storage_ctx, nimffi_str(filepath), chunk_size, on_str_reply, r) != RET_OK)
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

    pthread_mutex_lock(&chunks_mutex);
    if (upload_progress_count == 0)
    {
        fprintf(stderr, "on_upload_progress never fired\n");
        ret = RET_ERR;
    }
    pthread_mutex_unlock(&chunks_mutex);

    return ret;
}

int download_init(StorageCtx *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    uint64_t chunk_size = 64 * 1024;

    if (storage_ctx_download_init(storage_ctx, nimffi_str(cid), chunk_size, true, on_str_reply, r) != RET_OK)
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

    if (storage_ctx_download_stream(storage_ctx, nimffi_str(cid), chunk_size, true,
                                    nimffi_str(filepath), on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, NULL);

    // The chunks reached the host through the on_download_chunk event.
    pthread_mutex_lock(&chunks_mutex);
    if (strncmp(chunks, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "streamed content mismatch, res:%s\n", chunks);
        ret = RET_ERR;
    }
    pthread_mutex_unlock(&chunks_mutex);

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

    if (storage_ctx_download_manifest(storage_ctx, nimffi_str(cid), on_str_reply, r) != RET_OK)
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

int check_toggle_private_queries(StorageCtx *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    // First toggle is false -> true
    if (storage_ctx_toggle_private_queries(storage_ctx, true, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);
    if (ret == RET_OK)
    {
        fprintf(stderr, "expected toggle(true) to fail when mix is not configured, got ok\n");
        free(res);
        return RET_ERR;
    }

    free(res);
    res = NULL;

    // Second toggle is true -> false
    r = alloc_resp();
    if (storage_ctx_toggle_private_queries(storage_ctx, false, on_str_reply, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    ret = is_resp_ok(r, &res);
    if (res == NULL || strcmp(res, "false") != 0)
    {
        fprintf(stderr, "toggle private queries content mismatch, res:%s\n", res ? res : "(null)");
        free(res);
        return RET_ERR;
    }

    free(res);
    return RET_OK;
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
    RUN_TEST(check_list(storage_ctx));
    RUN_TEST(check_space(storage_ctx));
    RUN_TEST(check_exists(storage_ctx, cid, true));
    RUN_TEST(check_delete(storage_ctx, cid));
    RUN_TEST(check_exists(storage_ctx, cid, false));

    free(cid);

    RUN_TEST(check_toggle_private_queries(storage_ctx));
    RUN_TEST(update_log_level(storage_ctx, "TRACE"));
    RUN_TEST(check_get_metrics(storage_ctx));
    RUN_TEST(cleanup(storage_ctx));

    END_SUITE
}
