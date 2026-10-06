// Evidence-only: undocumented IOReport device-total counters, never PID attribution.
// Derived from the UID501 capability probe recorded in cp5-gpu-capability-research.json.
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
extern CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern void *IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(void *, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static double now(void) { struct timespec value; if (clock_gettime(CLOCK_UPTIME_RAW, &value)) exit(3); return value.tv_sec + value.tv_nsec / 1e9; }
static void text(CFStringRef value, char *buffer, size_t size) { buffer[0] = 0; if (value) CFStringGetCString(value, buffer, size, kCFStringEncodingUTF8); }
static void quoted(const char *value) {
    putchar('"'); for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 32) printf("\\u%04x", *p); else putchar(*p);
    } putchar('"');
}
static int fail(const char *message) {
    printf("{\"type\":\"error\",\"scope\":\"device-total\",\"attribution\":\"unavailable\",\"available\":false,\"error\":");
    quoted(message); printf("}\n"); fflush(stdout); return 1;
}
static CFArrayRef items(CFDictionaryRef sample) {
    if (!sample) return NULL;
    CFTypeRef result = CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    return result && CFGetTypeID(result) == CFArrayGetTypeID() ? result : NULL;
}
static int kind(CFDictionaryRef item) {
    char group[256], subgroup[256], name[256];
    text(IOReportChannelGetGroup(item), group, sizeof group);
    text(IOReportChannelGetSubGroup(item), subgroup, sizeof subgroup);
    text(IOReportChannelGetChannelName(item), name, sizeof name);
    if (!strcmp(group, "Energy Model") && !strcmp(name, "GPU Energy")) return 1;
    if (!strcmp(group, "GPU Stats") && !strcmp(subgroup, "GPU Performance States")) return 2;
    return 0;
}
static int valid(CFArrayRef channels) {
    int energy = 0, residency = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(channels); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(channels, i); char unit[256];
        text(IOReportChannelGetUnitLabel(item), unit, sizeof unit);
        int category = kind(item);
        if (category == 1) { if (strcmp(unit, "nJ") || IOReportSimpleGetIntegerValue(item, 0) < 0) return 0; energy++; }
        else if (category == 2) {
            if (strcmp(unit, "24Mticks")) return 0;
            int count = IOReportStateGetCount(item), off = 0; double total = 0;
            if (count < 1 || count > 64) return 0;
            for (int j = 0; j < count; j++) {
                char name[256]; text(IOReportStateGetNameForIndex(item, j), name, sizeof name);
                int64_t ticks = IOReportStateGetResidency(item, j);
                if (!name[0] || ticks < 0) return 0;
                if (!strcmp(name, "OFF")) off++;
                total += (double)ticks;
            }
            if (off != 1 || total <= 0) return 0;
            residency++;
        } else return 0;
    }
    return energy == 1 && residency >= 1;
}
static void sample(CFArrayRef channels, unsigned index, double origin, double begin, double end) {
    printf("{\"type\":\"sample\",\"available\":true,\"scope\":\"device-total\",\"attribution\":\"unavailable\",\"index\":%u,\"startUptimeSeconds\":%.9f,\"endUptimeSeconds\":%.9f,\"elapsedSeconds\":%.9f,\"runElapsedSeconds\":%.9f,\"channels\":[", index, begin, end, end - begin, end - origin);
    for (CFIndex i = 0; i < CFArrayGetCount(channels); i++) {
        if (i) putchar(','); CFDictionaryRef item = CFArrayGetValueAtIndex(channels, i);
        char name[256]; text(IOReportChannelGetChannelName(item), name, sizeof name);
        printf("{\"channel\":"); quoted(name);
        if (kind(item) == 1) {
            int64_t energy = IOReportSimpleGetIntegerValue(item, 0);
            printf(",\"unit\":\"nJ\",\"delta\":%lld,\"modeledAverageMilliwatts\":%.9f}", (long long)energy, (double)energy / (end - begin) / 1e6);
        } else {
            double total = 0, off = 0; int count = IOReportStateGetCount(item);
            printf(",\"unit\":\"24Mticks\",\"states\":[");
            for (int j = 0; j < count; j++) {
                if (j) putchar(','); text(IOReportStateGetNameForIndex(item, j), name, sizeof name);
                int64_t ticks = IOReportStateGetResidency(item, j); total += (double)ticks;
                if (!strcmp(name, "OFF")) off += (double)ticks;
                printf("{\"name\":"); quoted(name); printf(",\"deltaTicks\":%lld}", (long long)ticks);
            }
            printf("],\"activePercent\":%.9f}", (total - off) / total * 100);
        }
    }
    printf("]}\n"); fflush(stdout);
}
static void sleep_until(double deadline) {
    for (;;) {
        double remaining = deadline - now(); if (remaining <= 0) return;
        struct timespec request = {.tv_sec = (time_t)remaining, .tv_nsec = (long)((remaining - (time_t)remaining) * 1e9)};
        if (request.tv_nsec >= 1000000000) { request.tv_sec++; request.tv_nsec -= 1000000000; }
        if (nanosleep(&request, NULL) && errno != EINTR) exit(3);
    }
}
int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return fail("Expected duration interval output.jsonl [--test-missing-channel]");
    char *end1, *end2; double duration = strtod(argv[1], &end1), interval = strtod(argv[2], &end2);
    if (*end1 || *end2 || !isfinite(duration) || !isfinite(interval) || duration <= 0 || duration > 3600 || interval < 0.1 || interval > duration || interval > 60) return fail("Invalid finite duration/interval bounds");
    if (argc == 5 && strcmp(argv[4], "--test-missing-channel")) return fail("Unknown test option");
    if (!freopen(argv[3], "wx", stdout)) { perror("output"); return 2; }
    if (!geteuid()) return fail("Normal non-root UID required; no elevation supported");
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0); CFArrayRef available = items(all);
    if (!available) return fail("IOReport channels unavailable");
    CFMutableDictionaryRef selected = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFMutableArrayRef chosen = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    int energy = 0, residency = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(available); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(available, i); int category = kind(item);
        if (category && argc != 5) { CFArrayAppendValue(chosen, item); energy += category == 1; residency += category == 2; }
    }
    if (energy != 1 || residency < 1) return fail("Required GPU Energy/GPU Performance States channel capability missing or ambiguous");
    CFDictionarySetValue(selected, CFSTR("IOReportChannels"), chosen);
    CFMutableDictionaryRef actual = NULL; void *subscription = IOReportCreateSubscription(NULL, selected, &actual, 0, NULL);
    if (!subscription) return fail("IOReport subscription unavailable");
    CFDictionaryRef previous = IOReportCreateSamples(subscription, selected, NULL);
    if (!previous) return fail("Initial IOReport sample unavailable");
    double origin = now(), previous_time = origin, next = origin + interval; unsigned index = 0;
    while (previous_time < origin + duration) {
        double deadline = fmin(next, origin + duration); sleep_until(deadline);
        CFDictionaryRef current = IOReportCreateSamples(subscription, selected, NULL); double current_time = now();
        if (!current) return fail("IOReport sample unavailable");
        CFDictionaryRef delta = IOReportCreateSamplesDelta(previous, current, NULL); CFArrayRef channels = items(delta);
        if (!channels || !valid(channels)) return fail("Required channels/units/residency shape unavailable or counter reset");
        sample(channels, ++index, origin, previous_time, current_time);
        CFRelease(delta); CFRelease(previous); previous = current; previous_time = current_time; next += interval;
    }
    CFRelease(previous); CFRelease(chosen); CFRelease(selected); CFRelease(all);
    // Subscription is an undocumented opaque handle: process exit owns teardown.
    // Never invent a private destructor or extend it into product dependencies.
    return 0;
}
