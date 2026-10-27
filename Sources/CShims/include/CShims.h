#ifndef CSHIMS_H
#define CSHIMS_H

/// Asks the file system holding both paths to copy the file itself: on an SMB share the server copies it and no
/// data crosses the network. `to` must not exist. Returns 0, or -1 with errno set (ENOTSUP, EXDEV…) when the file
/// system can't, so the caller copies the usual way.
int suzu_server_copy(const char *from, const char *to);

#endif
