#include "CurlImpersonate.h"

#include <ctype.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// The parts of curl.h used here (their values are curl's ABI).
typedef void CURL;
typedef void curl_mime;
typedef void curl_mimepart;
typedef int CURLcode;
struct curl_slist;
enum {
    CURLE_OK = 0,
    CURLOPT_WRITEDATA = 10001,
    CURLOPT_URL = 10002,
    CURLOPT_ERRORBUFFER = 10010,
    CURLOPT_POSTFIELDS = 10015,
    CURLOPT_HTTPHEADER = 10023,
    CURLOPT_HEADERDATA = 10029,
    CURLOPT_COOKIEFILE = 10031,
    CURLOPT_XFERINFODATA = 10057,
    CURLOPT_ACCEPT_ENCODING = 10102,
    CURLOPT_MIMEPOST = 10269,
    CURLOPT_TIMEOUT = 13,
    CURLOPT_NOPROGRESS = 43,
    CURLOPT_POST = 47,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_WRITEFUNCTION = 20011,
    CURLOPT_HEADERFUNCTION = 20079,
    CURLOPT_XFERINFOFUNCTION = 20219,
    CURLOPT_POSTFIELDSIZE_LARGE = 30120,
    CURLINFO_RESPONSE_CODE = 0x200000 + 2,
    CURL_GLOBAL_DEFAULT = 3,
    CURL_ERROR_SIZE = 256,
};

static struct {
    CURLcode (*globalInit)(long);
    CURL *(*easyInit)(void);
    void (*easyCleanup)(CURL *);
    void (*easyReset)(CURL *);
    CURLcode (*easySetopt)(CURL *, int, ...);
    CURLcode (*easyGetinfo)(CURL *, int, ...);
    CURLcode (*easyPerform)(CURL *);
    CURLcode (*easyImpersonate)(CURL *, const char *, int);
    const char *(*easyStrerror)(CURLcode);
    struct curl_slist *(*slistAppend)(struct curl_slist *, const char *);
    void (*slistFreeAll)(struct curl_slist *);
    curl_mime *(*mimeInit)(CURL *);
    void (*mimeFree)(curl_mime *);
    curl_mimepart *(*mimeAddpart)(curl_mime *);
    CURLcode (*mimeName)(curl_mimepart *, const char *);
    CURLcode (*mimeType)(curl_mimepart *, const char *);
    CURLcode (*mimeData)(curl_mimepart *, const char *, size_t);
} curl;

static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;
static const char *loadPath;
static char loadError[512];
static int loadResult = -1;

static void load(void) {
    void *library = dlopen(loadPath, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        snprintf(loadError, sizeof loadError, "%s", dlerror());
        return;
    }
    struct { void **pointer; const char *name; } symbols[] = {
        {(void **)&curl.globalInit, "curl_global_init"},
        {(void **)&curl.easyInit, "curl_easy_init"},
        {(void **)&curl.easyCleanup, "curl_easy_cleanup"},
        {(void **)&curl.easyReset, "curl_easy_reset"},
        {(void **)&curl.easySetopt, "curl_easy_setopt"},
        {(void **)&curl.easyGetinfo, "curl_easy_getinfo"},
        {(void **)&curl.easyPerform, "curl_easy_perform"},
        {(void **)&curl.easyImpersonate, "curl_easy_impersonate"},
        {(void **)&curl.easyStrerror, "curl_easy_strerror"},
        {(void **)&curl.slistAppend, "curl_slist_append"},
        {(void **)&curl.slistFreeAll, "curl_slist_free_all"},
        {(void **)&curl.mimeInit, "curl_mime_init"},
        {(void **)&curl.mimeFree, "curl_mime_free"},
        {(void **)&curl.mimeAddpart, "curl_mime_addpart"},
        {(void **)&curl.mimeName, "curl_mime_name"},
        {(void **)&curl.mimeType, "curl_mime_type"},
        {(void **)&curl.mimeData, "curl_mime_data"},
    };
    for (size_t i = 0; i < sizeof symbols / sizeof *symbols; i++) {
        *symbols[i].pointer = dlsym(library, symbols[i].name);
        if (!*symbols[i].pointer) {
            snprintf(loadError, sizeof loadError, "%s is missing %s", loadPath, symbols[i].name);
            return;
        }
    }
    if (curl.globalInit(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        snprintf(loadError, sizeof loadError, "curl_global_init failed");
        return;
    }
    loadResult = 0;
}

int MPCurlLoad(const char *path, char *error, size_t errorSize) {
    if (!loadPath) loadPath = strdup(path);
    pthread_once(&loadOnce, load);
    if (loadResult != 0 && errorSize > 0) snprintf(error, errorSize, "%s", loadError);
    return loadResult;
}

struct MPCurlSession {
    CURL *handle;
    atomic_int cancelled;
};

MPCurlSession *MPCurlSessionCreate(void) {
    if (loadResult != 0) return NULL;
    MPCurlSession *session = calloc(1, sizeof *session);
    if (!session) return NULL;
    session->handle = curl.easyInit();
    if (!session->handle) {
        free(session);
        return NULL;
    }
    return session;
}

void MPCurlSessionFree(MPCurlSession *session) {
    curl.easyCleanup(session->handle);
    free(session);
}

void MPCurlSessionCancel(MPCurlSession *session) {
    atomic_store(&session->cancelled, 1);
}

static int progress(void *data, int64_t downloadTotal, int64_t downloaded, int64_t uploadTotal, int64_t uploaded) {
    (void)downloadTotal, (void)downloaded, (void)uploadTotal, (void)uploaded;
    return atomic_load(&((MPCurlSession *)data)->cancelled) ? 1 : 0;
}

static size_t writeBody(char *data, size_t size, size_t count, void *context) {
    MPCurlResponse *response = context;
    size_t length = size * count;
    char *body = realloc(response->body, response->bodyLength + length + 1);
    if (!body) return 0;
    memcpy(body + response->bodyLength, data, length);
    response->bodyLength += length;
    body[response->bodyLength] = 0;
    response->body = body;
    return length;
}

static size_t writeHeader(char *data, size_t size, size_t count, void *context) {
    MPCurlResponse *response = context;
    size_t length = size * count;
    static const char name[] = "location:";
    if (length > sizeof name - 1 && strncasecmp(data, name, sizeof name - 1) == 0) {
        size_t start = sizeof name - 1, end = length;
        while (start < end && isspace((unsigned char)data[start])) start++;
        while (end > start && isspace((unsigned char)data[end - 1])) end--;
        free(response->location);
        response->location = strndup(data + start, end - start);
    }
    return length;
}

int MPCurlSessionPost(
    MPCurlSession *session, const char *url, const char *target, const char *const *headers, size_t headerCount,
    const void *body, size_t bodyLength, const MPCurlPart *parts, size_t partCount, long timeoutSeconds,
    MPCurlResponse *response
) {
    memset(response, 0, sizeof *response);
    atomic_store(&session->cancelled, 0);
    CURL *handle = session->handle;
    // Clears the last request's options, but keeps its cookies and connections.
    curl.easyReset(handle);
    CURLcode code = curl.easyImpersonate(handle, target, 1);
    if (code != CURLE_OK) {
        snprintf(response->error, sizeof response->error, "can't impersonate %s: %s", target, curl.easyStrerror(code));
        return code;
    }
    struct curl_slist *list = NULL;
    for (size_t i = 0; i < headerCount; i++) list = curl.slistAppend(list, headers[i]);
    curl_mime *mime = NULL;
    if (partCount > 0) {
        mime = curl.mimeInit(handle);
        for (size_t i = 0; i < partCount; i++) {
            curl_mimepart *part = curl.mimeAddpart(mime);
            curl.mimeName(part, parts[i].name);
            if (parts[i].contentType) curl.mimeType(part, parts[i].contentType);
            curl.mimeData(part, parts[i].data ? parts[i].data : "", parts[i].length);
        }
    }
    char error[CURL_ERROR_SIZE] = "";
    curl.easySetopt(handle, CURLOPT_URL, url);
    // Decodes compressed responses (the encodings Chrome's header offers, which this sends as it is).
    curl.easySetopt(handle, CURLOPT_ACCEPT_ENCODING, "gzip, deflate, br, zstd");
    curl.easySetopt(handle, CURLOPT_COOKIEFILE, "");
    curl.easySetopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
    curl.easySetopt(handle, CURLOPT_TIMEOUT, timeoutSeconds);
    curl.easySetopt(handle, CURLOPT_ERRORBUFFER, error);
    if (list) curl.easySetopt(handle, CURLOPT_HTTPHEADER, list);
    if (mime) {
        curl.easySetopt(handle, CURLOPT_MIMEPOST, mime);
    } else {
        curl.easySetopt(handle, CURLOPT_POST, 1L);
        curl.easySetopt(handle, CURLOPT_POSTFIELDSIZE_LARGE, (int64_t)bodyLength);
        curl.easySetopt(handle, CURLOPT_POSTFIELDS, body ? body : "");
    }
    curl.easySetopt(handle, CURLOPT_WRITEFUNCTION, writeBody);
    curl.easySetopt(handle, CURLOPT_WRITEDATA, response);
    curl.easySetopt(handle, CURLOPT_HEADERFUNCTION, writeHeader);
    curl.easySetopt(handle, CURLOPT_HEADERDATA, response);
    curl.easySetopt(handle, CURLOPT_NOPROGRESS, 0L);
    curl.easySetopt(handle, CURLOPT_XFERINFOFUNCTION, progress);
    curl.easySetopt(handle, CURLOPT_XFERINFODATA, session);
    code = curl.easyPerform(handle);
    if (code == CURLE_OK) {
        curl.easyGetinfo(handle, CURLINFO_RESPONSE_CODE, &response->status);
    } else {
        snprintf(response->error, sizeof response->error, "%s", error[0] ? error : curl.easyStrerror(code));
    }
    // Nothing may point at the freed list, form or error buffer once this returns.
    curl.easyReset(handle);
    if (mime) curl.mimeFree(mime);
    curl.slistFreeAll(list);
    return code;
}

void MPCurlResponseFree(MPCurlResponse *response) {
    free(response->location);
    free(response->body);
    response->location = NULL;
    response->body = NULL;
}
