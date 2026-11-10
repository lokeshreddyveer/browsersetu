// Asks the operating system what a RUNNING process's sandbox allows, with sandbox_check(). Native C because sandbox_check is variadic and Python's ctypes cannot pass variadic arguments on Apple Silicon
// (every path query then fails with -1, which is NOT a denial: this tool reports errors as errors).
//   sandbox_query <pid> <operation> [path]        prints ALLOWED, DENIED or ERROR; exit 0 / 1 / 2
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
#define SANDBOX_FILTER_NONE 0
#define SANDBOX_FILTER_PATH 1
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: sandbox_query <pid> <operation> [path]\n"); return 2; }
    pid_t pid = (pid_t)atoi(argv[1]);
    int r = argc >= 4 ? sandbox_check(pid, argv[2], SANDBOX_FILTER_PATH, argv[3]) : sandbox_check(pid, argv[2], SANDBOX_FILTER_NONE);
    if (r == 0) { puts("ALLOWED"); return 0; }
    if (r == 1) { puts("DENIED"); return 1; }
    printf("ERROR %d\n", r); return 2;
}
