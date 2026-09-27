/* PCRE2 harness of z-regex's cross-engine benchmark (docs/BENCHMARKS.md).
 * T2 cases only (backreferences, lookaround) and the adversarial ones.
 *
 *   pcre2_xbench case ID PATTERN CORPUS_FILE SHORT   JSON: JIT and interpreter
 *   pcre2_xbench adv ID PATTERN N (jit|interp) [SUFFIX]   one adversarial run
 *                                                   ('a' x N + SUFFIX, default "c")
 *
 * 8-bit library, no UTF (the T2 corpora are ASCII; ECMAScript without u
 * matches code units). findAll copies every match's ovector into a growing
 * heap array (the allocating wrapper); "execAt" is a pcre2_match loop with
 * one reused match_data. bytes: PCRE2_INFO_SIZE (+ PCRE2_INFO_JITSIZE for
 * the JIT). Build: cc -O2 -o pcre2_xbench pcre2_xbench.c -lpcre2-8 */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static int cmpd(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double median(double *v, int n) {
  qsort(v, n, sizeof *v, cmpd);
  return v[n / 2];
}

static pcre2_code *compile(const char *p, int jit) {
  int err;
  PCRE2_SIZE off;
  pcre2_code *re = pcre2_compile((PCRE2_SPTR)p, PCRE2_ZERO_TERMINATED, 0, &err, &off, NULL);
  if (!re) {
    fprintf(stderr, "compile error %d at %zu\n", err, (size_t)off);
    exit(1);
  }
  if (jit && pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) != 0) {
    fprintf(stderr, "jit compile failed\n");
    exit(1);
  }
  return re;
}

static uint32_t opts(int jit) { return jit ? 0 : PCRE2_NO_JIT; }

/* Loop over every match; with `collect`, copy each ovector to the heap. */
static size_t pass(pcre2_code *re, pcre2_match_data *md, const char *s, size_t len, int jit, int collect) {
  size_t n = 0, i = 0, cap = 0;
  PCRE2_SIZE *all = NULL;
  uint32_t pairs = pcre2_get_ovector_count(md);
  while (i <= len) {
    int rc = pcre2_match(re, (PCRE2_SPTR)s, len, i, opts(jit), md, NULL);
    if (rc < 0) break;
    PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
    if (collect) {
      if ((n + 1) * pairs * 2 > cap) {
        cap = cap ? cap * 2 : 1024;
        while (cap < (n + 1) * pairs * 2) cap *= 2;
        all = realloc(all, cap * sizeof *all);
      }
      memcpy(all + n * pairs * 2, ov, pairs * 2 * sizeof *ov);
    }
    n++;
    i = ov[1] == ov[0] ? ov[1] + 1 : ov[1];
  }
  free(all);
  return n;
}

static double timed(pcre2_code *re, pcre2_match_data *md, const char *s, size_t len, int jit, int collect, size_t *matches) {
  *matches = pass(re, md, s, len, jit, collect);
  double t[5], spent = 0;
  int n = 0;
  while (n < 5) {
    double t0 = now();
    *matches = pass(re, md, s, len, jit, collect);
    t[n] = now() - t0;
    spent += t[n++];
    if (spent > 5) break;
  }
  return len / (1024.0 * 1024.0) / median(t, n);
}

static void run_case(const char *id, const char *pattern, const char *file, const char *shortin) {
  FILE *f = fopen(file, "rb");
  fseek(f, 0, SEEK_END);
  size_t len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *s = malloc(len + 1);
  if (fread(s, 1, len, f) != len) exit(1);
  fclose(f);
  printf("[");
  for (int jit = 1; jit >= 0; jit--) {
    double cs[21];
    for (int k = 0; k < 21; k++) {
      double t0 = now();
      pcre2_code *r = compile(pattern, jit);
      cs[k] = (now() - t0) * 1e6;
      pcre2_code_free(r);
    }
    pcre2_code *re = compile(pattern, jit);
    size_t size = 0, jsize = 0;
    pcre2_pattern_info(re, PCRE2_INFO_SIZE, &size);
    if (jit) pcre2_pattern_info(re, PCRE2_INFO_JITSIZE, &jsize);
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
    size_t m1, m2;
    double fa = timed(re, md, s, len, jit, 1, &m1);
    double ex = timed(re, md, s, len, jit, 0, &m2);
    size_t slen = strlen(shortin);
    for (int k = 0; k < 10000; k++) pcre2_match(re, (PCRE2_SPTR)shortin, slen, 0, opts(jit), md, NULL);
    double sn[11];
    const int iters = 200000;
    for (int k = 0; k < 11; k++) {
      double t0 = now();
      for (int j = 0; j < iters; j++) pcre2_match(re, (PCRE2_SPTR)shortin, slen, 0, opts(jit), md, NULL);
      sn[k] = (now() - t0) * 1e9 / iters;
    }
    printf("%s{\"engine\":\"%s\",\"id\":\"%s\",\"findall_mbps\":%.3f,\"execat_mbps\":%.3f,\"matches\":%zu,\"exec_matches\":%zu,\"short_ns\":%.2f,\"compile_us\":%.3f,\"bytes\":%zu}",
           jit ? "" : ",", jit ? "pcre2_jit" : "pcre2_interp", id, fa, ex, m1, m2, median(sn, 11), median(cs, 21), size + jsize);
    pcre2_match_data_free(md);
    pcre2_code_free(re);
  }
  printf("]\n");
  free(s);
}

int main(int argc, char **argv) {
  if (argc >= 6 && !strcmp(argv[1], "case")) {
    run_case(argv[2], argv[3], argv[4], argv[5]);
    return 0;
  }
  if (argc >= 6 && !strcmp(argv[1], "adv")) {
    int n = atoi(argv[4]), jit = !strcmp(argv[5], "jit");
    const char *suffix = argc >= 7 ? argv[6] : "c";
    size_t sl = strlen(suffix);
    char *s = malloc(n + sl + 1);
    memset(s, 'a', n);
    memcpy(s + n, suffix, sl + 1);
    pcre2_code *re = compile(argv[3], jit);
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
    double t0 = now();
    int rc = pcre2_match(re, (PCRE2_SPTR)s, n + sl, 0, opts(jit), md, NULL);
    double ms = (now() - t0) * 1e3;
    const char *outcome = rc >= 0 ? "match" : rc == PCRE2_ERROR_NOMATCH ? "no match" : rc == PCRE2_ERROR_MATCHLIMIT ? "match limit" : rc == PCRE2_ERROR_JIT_STACKLIMIT ? "JIT stack limit" : "error";
    printf("{\"engine\":\"%s\",\"id\":\"%s\",\"n\":%d,\"ms\":%.4f,\"outcome\":\"%s\"}\n", jit ? "pcre2_jit" : "pcre2_interp", argv[2], n, ms, outcome);
    return 0;
  }
  fprintf(stderr, "usage: see the header\n");
  return 2;
}
