// Vendored from FormatCore bench-kit/bench-core.h by tools/sync.sh: edit it there, then sync.
// The measurement core of the C and C++ benchmark harnesses of the format libraries (the measure()
// that was byte-identical in KdlBeef's, XmlBeef's and JsonBeef's bench/compare/c/bench.h, with the same
// constants in TomlBeef's), and the format-independent input helpers. Every harness in bench/compare
// follows the same rule (FormatCore.Testing's Bench.Measure is the Beef copy):
//   warm up for at least 1 s (at least one run), then time single runs until at least `min_samples`
//   were taken and at least 60% of them lie within ±10% of their median ("converged"), or 10 s of
//   measuring or 1000 samples have passed ("capped"). The median sample is reported.
// A format's bench.h includes this and adds its check line, its input kinds and its usage text.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BENCH_WARMUP_NS 1e9
#define BENCH_MAX_NS 10e9
#define BENCH_MAX_SAMPLES 1000
#define BENCH_WINDOW 0.10
#define BENCH_MAJORITY 0.6
// Zero bytes after every input buffer (simdjson reads up to 64 bytes past the end); a format may
// define less before including this file
#ifndef BENCH_PADDING
#define BENCH_PADDING 64
#endif

static double bench_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static int bench_cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

typedef struct
{
	double median_ns;
	int samples;
	bool converged;
} measurement_t;

typedef void (*bench_op)(void *ctx);

static measurement_t measure(bench_op op, void *ctx, int min_samples)
{
	double warm = bench_now_ns();
	do
		op(ctx);
	while (bench_now_ns() - warm < BENCH_WARMUP_NS);

	static double samples[BENCH_MAX_SAMPLES], sorted[BENCH_MAX_SAMPLES];
	measurement_t m = {0};
	double start = bench_now_ns();
	int n = 0;
	while (n < BENCH_MAX_SAMPLES)
	{
		double t0 = bench_now_ns();
		op(ctx);
		samples[n++] = bench_now_ns() - t0;
		memcpy(sorted, samples, sizeof(double) * n);
		qsort(sorted, n, sizeof(double), bench_cmp);
		double median = (n % 2) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		m.median_ns = median;
		m.samples = n;
		if (n >= min_samples)
		{
			int within = 0;
			for (int i = 0; i < n; i++)
				within += samples[i] >= median * (1 - BENCH_WINDOW) && samples[i] <= median * (1 + BENCH_WINDOW);
			if (within >= BENCH_MAJORITY * n)
			{
				m.converged = true;
				break;
			}
		}
		if (bench_now_ns() - start >= BENCH_MAX_NS)
			break;
	}
	return m;
}

// Result line: "<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)"
static void print_result(measurement_t m, long bytes)
{
	double ms = m.median_ns / 1e6;
	printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, bytes / 1048576.0 / (ms / 1000.0), m.samples,
		m.converged ? "converged" : "capped");
	fflush(stdout);
}

// ---- Inputs ----

static bool bench_ends_with(const char *s, const char *suffix)
{
	size_t a = strlen(s), b = strlen(suffix);
	return a >= b && strcmp(s + a - b, suffix) == 0;
}

// A NUL-terminated copy followed by BENCH_PADDING zero bytes
static char *bench_copy_padded(const char *src, size_t len)
{
	char *p = (char *)calloc(1, len + 1 + BENCH_PADDING);
	memcpy(p, src, len);
	return p;
}

// The whole file, NUL-terminated and padded; exits with status 2 if it cannot be read
static char *bench_read_file(const char *path, long *size)
{
	FILE *f = fopen(path, "rb");
	if (!f)
	{
		fprintf(stderr, "cannot open %s\n", path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	long length = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *data = (char *)calloc(1, length + 1 + BENCH_PADDING);
	if (fread(data, 1, length, f) != (size_t)length)
		exit(2);
	fclose(f);
	*size = length;
	return data;
}

typedef struct
{
	char *data; // NUL-terminated, followed by BENCH_PADDING zero bytes
	size_t size;
} bench_doc_t;

// The non-empty lines of `text` (a batch input: one document per line), each its own padded buffer;
// returns the count and sets *docs (malloc'ed)
static int bench_split_lines(const char *text, long size, bench_doc_t **docs)
{
	int count = 0, capacity = 16;
	*docs = (bench_doc_t *)malloc(sizeof(bench_doc_t) * capacity);
	const char *p = text, *end = text + size;
	while (p < end)
	{
		const char *nl = (const char *)memchr(p, '\n', end - p);
		const char *stop = nl ? nl : end;
		if (stop > p)
		{
			if (count == capacity)
			{
				capacity *= 2;
				*docs = (bench_doc_t *)realloc(*docs, sizeof(bench_doc_t) * capacity);
			}
			(*docs)[count].data = bench_copy_padded(p, stop - p);
			(*docs)[count].size = stop - p;
			count++;
		}
		p = stop + 1;
	}
	return count;
}

// Unicode code points in UTF-8 text: every byte that is not a continuation byte
static long utf8_chars(const char *s, size_t len)
{
	long n = 0;
	for (size_t i = 0; i < len; i++)
		n += ((unsigned char)s[i] & 0xC0) != 0x80;
	return n;
}
