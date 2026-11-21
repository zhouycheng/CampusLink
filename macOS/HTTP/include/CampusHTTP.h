#ifndef CAMPUS_HTTP_H
#define CAMPUS_HTTP_H
#include <stddef.h>

typedef struct {
    unsigned char *bytes;
    size_t size;
    long status;
    int gb_encoding;
    int over_limit;
} CampusResponse;

// Caller releases response.bytes with free(), including after an error.
int campus_http_get(const char *url, const char *referer, CampusResponse *response);

#endif
