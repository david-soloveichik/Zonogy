// Validates the exact user's Dock process before an injection, including after authorization.
#ifndef ZONOGY_INSTANT_MINIMIZE_TARGET_H
#define ZONOGY_INSTANT_MINIMIZE_TARGET_H
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int validate_dock(const char *pid_text, const char *uid_text, const char *start_text) {
    char *end = NULL;
    long pid = strtol(pid_text, &end, 10);
    if (!*pid_text || *end || pid <= 1 || pid > INT_MAX) return 0;
    long uid = strtol(uid_text, &end, 10);
    if (!*uid_text || *end || uid < 0 || uid > INT_MAX) return 0;
    double start = strtod(start_text, &end);
    if (!*start_text || *end || !isfinite(start) || start <= 0) return 0;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath((int)pid, path, sizeof(path)) <= 0) return 0;
    double actual_start = info.pbi_start_tvsec + info.pbi_start_tvusec / 1000000.0;
    return info.pbi_uid == (uid_t)uid && fabs(actual_start - start) < 0.001 &&
        strcmp(path, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock") == 0;
}
#endif
