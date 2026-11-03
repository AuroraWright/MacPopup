#include <stddef.h>

#pragma clang assume_nonnull begin

/// HTTP requests with libcurl-impersonate (github.com/lexiforest/curl-impersonate, which scripts/build.sh puts in the
/// app), made to look like a browser's down to its TLS and HTTP/2 fingerprints, as owocr makes them with curl_cffi.
/// The library is loaded at runtime (MPCurlLoad), so MacPopup builds and runs without it.
typedef struct MPCurlSession MPCurlSession;

/// A part of a multipart form.
typedef struct {
    const char *name;
    const char *_Nullable contentType;
    const void *_Nullable data;
    size_t length;
} MPCurlPart;

typedef struct {
    long status;
    /// The Location header as sent (NULL without one).
    char *_Nullable location;
    char *_Nullable body;
    size_t bodyLength;
    char error[256];
} MPCurlResponse;

/// Loads the library at `path`. 0 on success; otherwise `error` says why. Later calls return the first one's result.
int MPCurlLoad(const char *path, char *error, size_t errorSize);

/// A session: its requests share cookies and connections. Requests on one session must not overlap. NULL if the
/// library isn't loaded.
MPCurlSession *_Nullable MPCurlSessionCreate(void);
void MPCurlSessionFree(MPCurlSession *session);
/// Makes the session's request in progress fail (from any thread).
void MPCurlSessionCancel(MPCurlSession *session);

/// POSTs `body` (or, with `parts`, a multipart form) to `url` as the browser `target` (a curl-impersonate target, e.g.
/// "chrome142") with its default headers and `headers` ("Name: value"), without following redirects. Returns 0, or a
/// CURLcode with `response->error` set. Free the response with MPCurlResponseFree either way.
int MPCurlSessionPost(
    MPCurlSession *session, const char *url, const char *target, const char *_Nonnull const *_Nullable headers, size_t headerCount,
    const void *_Nullable body, size_t bodyLength, const MPCurlPart *_Nullable parts, size_t partCount, long timeoutSeconds,
    MPCurlResponse *response
);
void MPCurlResponseFree(MPCurlResponse *response);

#pragma clang assume_nonnull end
