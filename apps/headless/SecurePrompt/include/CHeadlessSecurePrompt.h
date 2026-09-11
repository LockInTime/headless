#ifndef C_HEADLESS_SECURE_PROMPT_H
#define C_HEADLESS_SECURE_PROMPT_H

#include <stddef.h>

enum headless_prompt_result {
    HEADLESS_PROMPT_SUCCESS = 0,
    HEADLESS_PROMPT_NOT_TTY = 1,
    HEADLESS_PROMPT_OPEN_FAILED = 2,
    HEADLESS_PROMPT_TERMINAL_FAILED = 3,
    HEADLESS_PROMPT_READ_FAILED = 4,
    HEADLESS_PROMPT_EMPTY = 5,
    HEADLESS_PROMPT_TOO_LONG = 6,
    HEADLESS_PROMPT_INTERRUPTED = 7,
    HEADLESS_PROMPT_NOT_FOREGROUND = 8
};

int headless_read_tty_line(
    const char *prompt,
    int hide_input,
    unsigned char **output,
    size_t *output_length
);

void headless_clear_and_free(unsigned char *bytes, size_t length);
void headless_secure_clear(unsigned char *bytes, size_t length);

#endif
