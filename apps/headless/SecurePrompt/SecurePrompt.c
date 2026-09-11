#include "CHeadlessSecurePrompt.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>

#define HEADLESS_PROMPT_MAX_BYTES 4096

static volatile sig_atomic_t caught_signal = 0;
static volatile sig_atomic_t signal_pipe_write = -1;
static const int handled_signals[] = {
    SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP
};

static void record_signal(int signal_number) {
    int saved_errno = errno;
    caught_signal = signal_number;
    if (signal_pipe_write >= 0) {
        unsigned char value = (unsigned char)signal_number;
        (void)write((int)signal_pipe_write, &value, 1);
    }
    errno = saved_errno;
}

static int write_all(int descriptor, const unsigned char *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result < 0 && errno == EINTR) {
            if (caught_signal != 0) return -1;
            continue;
        }
        if (result <= 0) {
            return -1;
        }
        written += (size_t)result;
    }
    return 0;
}

static void restore_handlers(const struct sigaction old_actions[]) {
    for (size_t index = 0; index < sizeof(handled_signals) / sizeof(handled_signals[0]); index++) {
        (void)sigaction(handled_signals[index], &old_actions[index], NULL);
    }
}

int headless_read_tty_line(
    const char *prompt,
    int hide_input,
    unsigned char **output,
    size_t *output_length
) {
    if (output == NULL || output_length == NULL || prompt == NULL) {
        return HEADLESS_PROMPT_READ_FAILED;
    }
    *output = NULL;
    *output_length = 0;
    if (!isatty(STDIN_FILENO)) {
        return HEADLESS_PROMPT_NOT_TTY;
    }

    int descriptor = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (descriptor < 0 || !isatty(descriptor)) {
        if (descriptor >= 0) {
            close(descriptor);
        }
        return HEADLESS_PROMPT_OPEN_FAILED;
    }
    if (tcgetpgrp(descriptor) != getpgrp()) {
        close(descriptor);
        return HEADLESS_PROMPT_NOT_FOREGROUND;
    }

    struct termios original;
    if (tcgetattr(descriptor, &original) != 0) {
        close(descriptor);
        return HEADLESS_PROMPT_TERMINAL_FAILED;
    }
    int signal_pipe[2] = { -1, -1 };
    if (pipe(signal_pipe) != 0
        || fcntl(signal_pipe[0], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(signal_pipe[1], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(signal_pipe[0], F_SETFL, O_NONBLOCK) != 0
        || fcntl(signal_pipe[1], F_SETFL, O_NONBLOCK) != 0) {
        if (signal_pipe[0] >= 0) close(signal_pipe[0]);
        if (signal_pipe[1] >= 0) close(signal_pipe[1]);
        close(descriptor);
        return HEADLESS_PROMPT_TERMINAL_FAILED;
    }

    struct sigaction action;
    struct sigaction old_actions[sizeof(handled_signals) / sizeof(handled_signals[0])];
    memset(&action, 0, sizeof(action));
    action.sa_handler = record_signal;
    sigemptyset(&action.sa_mask);
    caught_signal = 0;
    signal_pipe_write = signal_pipe[1];
    for (size_t index = 0; index < sizeof(handled_signals) / sizeof(handled_signals[0]); index++) {
        if (sigaction(handled_signals[index], &action, &old_actions[index]) != 0) {
            while (index > 0) {
                index--;
                (void)sigaction(handled_signals[index], &old_actions[index], NULL);
            }
            signal_pipe_write = -1;
            close(signal_pipe[0]);
            close(signal_pipe[1]);
            close(descriptor);
            return HEADLESS_PROMPT_TERMINAL_FAILED;
        }
    }

    struct termios configured = original;
    if (hide_input) {
        configured.c_lflag &= (tcflag_t)~(ECHO | ECHONL | ICANON);
        configured.c_cc[VMIN] = 1;
        configured.c_cc[VTIME] = 0;
        if (tcsetattr(descriptor, TCSAFLUSH, &configured) != 0) {
            restore_handlers(old_actions);
            signal_pipe_write = -1;
            close(signal_pipe[0]);
            close(signal_pipe[1]);
            close(descriptor);
            return HEADLESS_PROMPT_TERMINAL_FAILED;
        }
    }

    int result = HEADLESS_PROMPT_SUCCESS;
    unsigned char *buffer = malloc(HEADLESS_PROMPT_MAX_BYTES + 1);
    size_t length = 0;
    if (caught_signal != 0) {
        result = HEADLESS_PROMPT_INTERRUPTED;
        goto cleanup;
    }
    if (buffer == NULL || write_all(
        descriptor, (const unsigned char *)prompt, strlen(prompt)
    ) != 0) {
        result = HEADLESS_PROMPT_READ_FAILED;
        goto cleanup;
    }

    while (length <= HEADLESS_PROMPT_MAX_BYTES) {
        if (caught_signal != 0) {
            result = HEADLESS_PROMPT_INTERRUPTED;
            goto cleanup;
        }
        fd_set readers;
        FD_ZERO(&readers);
        FD_SET(descriptor, &readers);
        FD_SET(signal_pipe[0], &readers);
        int maximum = descriptor > signal_pipe[0] ? descriptor : signal_pipe[0];
        int ready = select(maximum + 1, &readers, NULL, NULL, NULL);
        if (ready < 0 && errno == EINTR) {
            if (caught_signal != 0) {
                result = HEADLESS_PROMPT_INTERRUPTED;
                goto cleanup;
            }
            continue;
        }
        if (ready < 0) {
            result = HEADLESS_PROMPT_READ_FAILED;
            goto cleanup;
        }
        if (caught_signal != 0 || FD_ISSET(signal_pipe[0], &readers)) {
            result = HEADLESS_PROMPT_INTERRUPTED;
            goto cleanup;
        }
        if (!FD_ISSET(descriptor, &readers)) {
            result = HEADLESS_PROMPT_READ_FAILED;
            goto cleanup;
        }
        if (tcgetpgrp(descriptor) != getpgrp()) {
            result = HEADLESS_PROMPT_NOT_FOREGROUND;
            goto cleanup;
        }
        unsigned char byte = 0;
        ssize_t count = read(descriptor, &byte, 1);
        if (count < 0 && errno == EINTR) {
            if (caught_signal != 0) {
                result = HEADLESS_PROMPT_INTERRUPTED;
                goto cleanup;
            }
            continue;
        }
        if (count <= 0) {
            result = HEADLESS_PROMPT_READ_FAILED;
            goto cleanup;
        }
        if (byte == '\n' || byte == '\r') {
            break;
        }
        if (byte == 0x7f || byte == 0x08) {
            if (length > 0) buffer[--length] = 0;
            continue;
        }
        if (byte == 0x15) {
            headless_secure_clear(buffer, length);
            length = 0;
            continue;
        }
        if (length == HEADLESS_PROMPT_MAX_BYTES) {
            result = HEADLESS_PROMPT_TOO_LONG;
            goto cleanup;
        }
        buffer[length++] = byte;
    }
    if (hide_input) {
        (void)write_all(descriptor, (const unsigned char *)"\n", 1);
    }
    if (length == 0) {
        result = HEADLESS_PROMPT_EMPTY;
        goto cleanup;
    }
    buffer[length] = 0;

cleanup:
    if (hide_input) {
        (void)tcflush(descriptor, TCIFLUSH);
        if (tcsetattr(descriptor, TCSAFLUSH, &original) != 0
            && result == HEADLESS_PROMPT_SUCCESS) {
            result = HEADLESS_PROMPT_TERMINAL_FAILED;
        }
    }
    restore_handlers(old_actions);
    signal_pipe_write = -1;
    close(signal_pipe[0]);
    close(signal_pipe[1]);
    close(descriptor);
    if (result == HEADLESS_PROMPT_SUCCESS) {
        *output = buffer;
        *output_length = length;
    } else if (buffer != NULL) {
        headless_clear_and_free(buffer, HEADLESS_PROMPT_MAX_BYTES + 1);
    }

    if (caught_signal != 0) {
        int signal_number = caught_signal;
        caught_signal = 0;
        raise(signal_number);
    }
    return result;
}

void headless_clear_and_free(unsigned char *bytes, size_t length) {
    if (bytes == NULL) {
        return;
    }
    headless_secure_clear(bytes, length);
    free(bytes);
}

void headless_secure_clear(unsigned char *bytes, size_t length) {
    volatile unsigned char *cursor = bytes;
    while (length-- > 0) {
        *cursor++ = 0;
    }
}
