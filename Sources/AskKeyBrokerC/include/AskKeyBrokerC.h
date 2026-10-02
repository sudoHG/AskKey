#ifndef ASKKEY_BROKER_C_H
#define ASKKEY_BROKER_C_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

ssize_t askkey_send_with_fds(int socket_fd, const void *bytes, size_t length,
                             const int *fds, size_t fd_count);
ssize_t askkey_receive_header_with_fds(int socket_fd, void *header, size_t header_length,
                                       int *fds, size_t fd_capacity, size_t *fd_count);
int askkey_spawn_process_group(const char *path, char *const argv[], char *const envp[],
                               int stdin_fd, int stdout_fd, int stderr_fd,
                               const char *working_directory,
                               int64_t deadline_seconds, int64_t deadline_nanoseconds,
                               pid_t *pid);

#endif
