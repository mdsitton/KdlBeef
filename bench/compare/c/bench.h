// Shared measurement for the C and C++ harnesses. Every harness in bench/compare follows the same
// rule (see run.sh):
//   warm up for at least 1 s (at least one run), then time single runs until at least `min_samples`
//   were taken and at least 60% of them lie within ±10% of their median ("converged"), or 10 s of
//   measuring or 1000 samples have passed. The median sample is reported.
// (Taken from TomlBeef's bench/compare/c/bench.h.)
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
}

// The whole file as a malloc'd buffer (NUL-terminated); exits on failure
static char *read_file(const char *path, long *size)
{
	FILE *f = fopen(path, "rb");
	if (!f)
	{
		fprintf(stderr, "cannot open %s\n", path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	*size = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *data = (char *)malloc(*size + 1);
	if (fread(data, 1, *size, f) != (size_t)*size)
		exit(2);
	data[*size] = 0;
	fclose(f);
	return data;
}
