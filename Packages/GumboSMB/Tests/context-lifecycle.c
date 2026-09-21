/* Gumbo context lifetime regression. Generated in-process contexts only; no network access. */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include "GumboSMB.h"

static void *exercise(void *argument)
{
    (void)argument;
    for (int iteration = 0; iteration < 2000; iteration++) {
        struct smb2_context *first = smb2_init_context();
        struct smb2_context *second = smb2_init_context();
        assert(first && second);
        assert(smb2_context_active(first));
        assert(smb2_context_active(second));
        smb2_destroy_context(first);
        assert(smb2_context_active(second));
        smb2_destroy_context(second);
    }
    return NULL;
}
int main(void)
{
    pthread_t threads[12];
    alarm(30); /* A corrupt cyclic list must fail promptly, not hang the test runner. */
    for (int i = 0; i < 12; i++) assert(pthread_create(&threads[i], NULL, exercise, NULL) == 0);
    for (int i = 0; i < 12; i++) assert(pthread_join(threads[i], NULL) == 0);
    alarm(0);
    assert(smb2_active_contexts() == NULL);
    puts("PASS 48000 parallel context lifetimes, isolated registries and bounded teardown");
    return 0;
}
