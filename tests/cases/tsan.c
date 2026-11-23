#include <pthread.h>

static int counter;

static void *work(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; i++)
        counter++; /* data race */
    return 0;
}

int main(void) {
    pthread_t t[2];
    for (int i = 0; i < 2; i++)
        pthread_create(&t[i], 0, work, 0);
    for (int i = 0; i < 2; i++)
        pthread_join(t[i], 0);
    return 0;
}
