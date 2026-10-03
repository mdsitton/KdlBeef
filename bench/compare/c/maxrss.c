// Vendored from FormatCore bench-kit/maxrss.c by tools/sync.sh: edit it there, then sync.
// maxrss <command...>: runs the command and writes "maxrss: <KiB>" to stderr when it exits: the peak
// resident set size of the process and of every descendant it waited for (getrusage's ru_maxrss as
// wait4 reports it for the child, the figure /usr/bin/time -f %M prints). Exits with the command's
// status (128 + the signal if it was killed). A benchmark's run.sh wraps every cell's process in it.
// (JsonBeef's bench/compare/c/maxrss.c.)
#include <signal.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child;

static void forward(int sig)
{
	if (child > 0)
		kill(child, sig);
}

int main(int argc, char **argv)
{
	if (argc < 2)
	{
		fprintf(stderr, "usage: maxrss <command...>\n");
		return 2;
	}
	child = fork();
	if (child < 0)
		return 2;
	if (child == 0)
	{
		execvp(argv[1], argv + 1);
		perror(argv[1]);
		_exit(127);
	}
	signal(SIGTERM, forward);
	signal(SIGINT, forward);
	int status;
	struct rusage usage;
	while (wait4(child, &status, 0, &usage) < 0)
		;
	fprintf(stderr, "maxrss: %ld\n", usage.ru_maxrss);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return WEXITSTATUS(status);
}
