#include "CampusHTTP.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define BODY_LIMIT (2u * 1024u * 1024u)
static pthread_once_t once = PTHREAD_ONCE_INIT;
static CURLcode init_result;
static void init_curl(void) { init_result = curl_global_init(CURL_GLOBAL_DEFAULT); }

static size_t receive(char *chunk, size_t size, size_t count, void *context) {
    CampusResponse *body = context;
    size_t length = size * count;
    if (!length) return 0;
    if (length > BODY_LIMIT - body->size) {
        body->over_limit = 1;
        return 0;
    }
    unsigned char *bytes = realloc(body->bytes, body->size + length);
    if (!bytes) return 0;
    memcpy(bytes + body->size, chunk, length);
    body->bytes = bytes;
    body->size += length;
    return length;
}

int campus_http_get(const char *url, const char *referer, CampusResponse *response) {
    pthread_once(&once, init_curl);
    if (init_result != CURLE_OK) return init_result;
    CURL *handle = curl_easy_init();
    if (!handle) return CURLE_FAILED_INIT;
    CURLcode result;
    // A new handle and fresh HTTP/1.1 connection prevent reuse and replay of a credential-bearing GET.
#define SET(option, value) if ((result = curl_easy_setopt(handle, option, value)) != CURLE_OK) goto done
    SET(CURLOPT_URL, url);
    SET(CURLOPT_REFERER, referer);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_FRESH_CONNECT, 1L);
    SET(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 3000L);
    SET(CURLOPT_TIMEOUT_MS, 8000L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_WRITEFUNCTION, receive);
    SET(CURLOPT_WRITEDATA, response);
#undef SET
    result = curl_easy_perform(handle);
    if (result == CURLE_OK) {
        char *type = NULL;
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &response->status);
        curl_easy_getinfo(handle, CURLINFO_CONTENT_TYPE, &type);
        response->gb_encoding = type && strcasestr(type, "gb");
    }
done:
    curl_easy_cleanup(handle);
    return result;
}
