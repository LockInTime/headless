#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

#include "CHeadlessSecurePrompt.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static const char *current_test = "startup";
static volatile sig_atomic_t observed_signal = 0;

static void observe_signal(int signal_number) {
    observed_signal = signal_number;
}

static void fail(const char *message) {
    fprintf(stderr, "secure prompt test (%s): %s\n", current_test, message);
    exit(1);
}

static void wait_for_prompt(int descriptor) {
    const char *expected = "Password: ";
    size_t matched = 0;
    while (matched < strlen(expected)) {
        fd_set readers;
        FD_ZERO(&readers);
        FD_SET(descriptor, &readers);
        struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
        int ready = select(descriptor + 1, &readers, NULL, NULL, &timeout);
        if (ready <= 0) {
            fail("timed out waiting for password prompt");
        }
        unsigned char byte = 0;
        if (read(descriptor, &byte, 1) != 1) {
            fail("could not read password prompt");
        }
        if (byte == (unsigned char)expected[matched]) {
            matched++;
        } else {
            matched = byte == (unsigned char)expected[0] ? 1 : 0;
        }
    }
}

static pid_t start_prompt(int *master, int expected_result, int expected_signal) {
    pid_t child = forkpty(master, NULL, NULL, NULL);
    if (child < 0) {
        fail("forkpty failed");
    }
    if (child == 0) {
        if (expected_signal != 0) {
            struct sigaction action;
            memset(&action, 0, sizeof(action));
            action.sa_handler = observe_signal;
            sigemptyset(&action.sa_mask);
            if (sigaction(expected_signal, &action, NULL) != 0) {
                _exit(5);
            }
        }
        unsigned char *secret = NULL;
        size_t length = 0;
        int result = headless_read_tty_line("Password: ", 1, &secret, &length);
        if (result != expected_result) {
            _exit(20 + result);
        }
        if (result == HEADLESS_PROMPT_SUCCESS) {
            const char expected[] = "synthetic-password";
            if (length != strlen(expected) || memcmp(secret, expected, length) != 0) {
                _exit(3);
            }
            headless_clear_and_free(secret, length + 1);
        }
        struct termios restored;
        if (tcgetattr(STDIN_FILENO, &restored) != 0 || (restored.c_lflag & ECHO) == 0) {
            _exit(4);
        }
        if (expected_signal != 0 && observed_signal != expected_signal) {
            _exit(6);
        }
        _exit(0);
    }
    wait_for_prompt(*master);
    return child;
}

static int secret_was_echoed(int descriptor, const char *secret) {
    unsigned char output[512];
    size_t length = 0;
    fd_set readers;
    FD_ZERO(&readers);
    FD_SET(descriptor, &readers);
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    if (select(descriptor + 1, &readers, NULL, NULL, &timeout) <= 0) {
        fail("timed out waiting for prompt completion output");
    }
    usleep(50000);
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        fail("could not make pseudo-terminal output nonblocking");
    }
    while (length < sizeof(output)) {
        ssize_t count = read(descriptor, output + length, sizeof(output) - length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        length += (size_t)count;
    }
    if (length >= strlen(secret)) {
        for (size_t index = 0; index <= length - strlen(secret); index++) {
            if (memcmp(output + index, secret, strlen(secret)) == 0) {
                return 1;
            }
        }
    }
    return 0;
}

static void test_success(void) {
    int master = -1;
    pid_t child = start_prompt(&master, HEADLESS_PROMPT_SUCCESS, 0);
    const char input[] = "synthetic-password\n";
    if (write(master, input, sizeof(input) - 1) != (ssize_t)(sizeof(input) - 1)) {
        fail("could not write synthetic password");
    }
    int echoed = secret_was_echoed(master, "synthetic-password");
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "secure prompt success child status: %d\n", status);
        fail("successful prompt child failed");
    }
    if (echoed) fail("password bytes were echoed by the terminal");
    close(master);
}

static void test_empty(void) {
    int master = -1;
    pid_t child = start_prompt(&master, HEADLESS_PROMPT_EMPTY, 0);
    if (write(master, "\n", 1) != 1) {
        fail("could not submit empty password");
    }
    (void)secret_was_echoed(master, "synthetic-password");
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fail("empty prompt child returned the wrong status");
    }
    close(master);
}

static void test_signal(int signal_number) {
    int master = -1;
    pid_t child = start_prompt(&master, HEADLESS_PROMPT_INTERRUPTED, signal_number);
    if (kill(child, signal_number) != 0) {
        fail("could not signal prompt child");
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fail("prompt child did not restore and propagate its signal");
    }
    close(master);
}

static void test_overlong_input(void) {
    int master = -1;
    pid_t child = start_prompt(&master, HEADLESS_PROMPT_TOO_LONG, 0);
    const char pattern[] = "overflow-secret";
    unsigned char input[4200];
    for (size_t index = 0; index < sizeof(input) - 1; index++) {
        input[index] = (unsigned char)pattern[index % (sizeof(pattern) - 1)];
    }
    input[sizeof(input) - 1] = '\n';
    size_t offset = 0;
    while (offset < sizeof(input)) {
        ssize_t count = write(master, input + offset, sizeof(input) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail("could not write overlong password");
        offset += (size_t)count;
    }
    int echoed = secret_was_echoed(master, pattern);
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fail("overlong prompt child returned the wrong status");
    }
    if (echoed) fail("overlong password bytes were echoed by the terminal");
    close(master);
}

static void test_continue_while_reading(void) {
    int master = -1;
    pid_t child = start_prompt(&master, HEADLESS_PROMPT_SUCCESS, 0);
    if (kill(child, SIGCONT) != 0) {
        fail("could not continue prompt child");
    }
    const char input[] = "synthetic-password\n";
    if (write(master, input, sizeof(input) - 1) != (ssize_t)(sizeof(input) - 1)) {
        fail("could not complete continued prompt");
    }
    int echoed = secret_was_echoed(master, "synthetic-password");
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fail("continued prompt child failed");
    }
    if (echoed) fail("password bytes were echoed by the terminal");
    close(master);
}

int main(void) {
    current_test = "success";
    test_success();
    current_test = "empty";
    test_empty();
    current_test = "SIGINT";
    test_signal(SIGINT);
    current_test = "SIGTERM";
    test_signal(SIGTERM);
    current_test = "SIGHUP";
    test_signal(SIGHUP);
    current_test = "SIGQUIT";
    test_signal(SIGQUIT);
    current_test = "SIGTSTP";
    test_signal(SIGTSTP);
    current_test = "SIGCONT";
    test_continue_while_reading();
    current_test = "overlong input";
    test_overlong_input();
    puts("Secure terminal prompt tests passed");
    return 0;
}
