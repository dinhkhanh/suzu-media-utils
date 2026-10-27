#include "CShims.h"
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// The kernel's copyfile (not copyfile(3), which reads and writes the data itself): smbfs answers it with an SMB
// server-side copy. Only reachable through syscall(2), which Swift can't call; Apple calls syscall(2) unsupported,
// so every caller falls back to an ordinary copy when this fails.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int suzu_server_copy(const char *from, const char *to) {
    struct stat st;
    if (stat(from, &st) != 0) return -1;
    return syscall(SYS_copyfile, from, to, st.st_mode & 07777, 0);
}
#pragma clang diagnostic pop
