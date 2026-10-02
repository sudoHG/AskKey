#include "AskKeyBrokerC.h"

#include <errno.h>
#include <spawn.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

ssize_t askkey_send_with_fds(int socket_fd, const void *bytes, size_t length,
                             const int *fds, size_t fd_count) {
    if (fd_count == 0 || fd_count > 4) { errno = EINVAL; return -1; }
    char control[CMSG_SPACE(sizeof(int) * 4)] = {0};
    struct iovec vector = {(void *)bytes, length};
    struct msghdr message = {0};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = CMSG_SPACE(sizeof(int) * fd_count);
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int) * fd_count);
    memcpy(CMSG_DATA(header), fds, sizeof(int) * fd_count);

    ssize_t sent;
    do { sent = sendmsg(socket_fd, &message, 0); } while (sent < 0 && errno == EINTR);
    if (sent <= 0) { return sent; }
    size_t offset = (size_t)sent;
    while (offset < length) {
        ssize_t written;
        do { written = write(socket_fd, (const char *)bytes + offset, length - offset); }
        while (written < 0 && errno == EINTR);
        if (written <= 0) { return -1; }
        offset += (size_t)written;
    }
    return (ssize_t)offset;
}

ssize_t askkey_receive_header_with_fds(int socket_fd, void *header, size_t header_length,
                                       int *fds, size_t fd_capacity, size_t *fd_count) {
    char control[CMSG_SPACE(sizeof(int) * 4)] = {0};
    struct iovec vector = {header, header_length};
    struct msghdr message = {0};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    ssize_t received;
    do { received = recvmsg(socket_fd, &message, MSG_WAITALL); }
    while (received < 0 && errno == EINTR);
    *fd_count = 0;
    if (received <= 0) { return received; }
    for (struct cmsghdr *item = CMSG_FIRSTHDR(&message); item != NULL;
         item = CMSG_NXTHDR(&message, item)) {
        if (item->cmsg_level != SOL_SOCKET || item->cmsg_type != SCM_RIGHTS) { continue; }
        if (item->cmsg_len < CMSG_LEN(0)) { errno = EPROTO; goto fail; }
        size_t count = (item->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        if (count > fd_capacity - *fd_count) { errno = EMSGSIZE; goto fail; }
        memcpy(fds + *fd_count, CMSG_DATA(item), count * sizeof(int));
        *fd_count += count;
    }
    if ((message.msg_flags & MSG_CTRUNC) != 0) {
        errno = EMSGSIZE;
        goto fail;
    }
    return received;

fail:
    for (size_t index = 0; index < *fd_count; index++) { close(fds[index]); }
    *fd_count = 0;
    return -1;
}

int askkey_spawn_process_group(const char *path, char *const argv[], char *const envp[],
                               int stdin_fd, int stdout_fd, int stderr_fd,
                               const char *working_directory,
                               int64_t deadline_seconds, int64_t deadline_nanoseconds,
                               pid_t *pid) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) { return result; }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }
    result = posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
    if (result == 0) { result = posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO); }
    if (result == 0) { result = posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO); }
    if (result == 0 && working_directory != NULL) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        result = posix_spawn_file_actions_addchdir_np(&actions, working_directory);
#pragma clang diagnostic pop
    }
    sigset_t default_signals;
    sigset_t signal_mask;
    sigemptyset(&default_signals);
    sigaddset(&default_signals, SIGINT);
    sigaddset(&default_signals, SIGTERM);
    sigaddset(&default_signals, SIGHUP);
    sigaddset(&default_signals, SIGPIPE);
    sigemptyset(&signal_mask);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    if (result == 0) { result = posix_spawnattr_setflags(&attributes, flags); }
    if (result == 0) { result = posix_spawnattr_setpgroup(&attributes, 0); }
    if (result == 0) { result = posix_spawnattr_setsigdefault(&attributes, &default_signals); }
    if (result == 0) { result = posix_spawnattr_setsigmask(&attributes, &signal_mask); }
    if (result == 0 && deadline_seconds >= 0) {
        struct timespec now;
        if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
            result = errno;
        } else if (now.tv_sec > deadline_seconds
                   || (now.tv_sec == deadline_seconds && now.tv_nsec >= deadline_nanoseconds)) {
            result = ETIMEDOUT;
        }
    }
    if (result == 0) { result = posix_spawn(pid, path, &actions, &attributes, argv, envp); }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}
