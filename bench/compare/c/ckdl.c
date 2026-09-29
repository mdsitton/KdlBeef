// ckdl benchmark: ckdl parse <file> <min-samples>
// ckdl is a pull (event) parser with no document: one parse runs kdl_parser_next_event to the end of
// the input (KDL v2 only, no comment events), touching every event. Prints the node count as a check
// line. It has no document to write, so there is no write mode (kdlpp covers ckdl's writer).
#include <kdl/kdl.h>
#include "bench.h"

typedef struct
{
	const char *text;
	long size;
	long nodes;
} ctx_t;

static long parse_all(ctx_t *c)
{
	kdl_str doc = {c->text, (size_t)c->size};
	kdl_parser *parser = kdl_create_string_parser(doc, KDL_READ_VERSION_2);
	long nodes = 0;
	for (;;)
	{
		kdl_event_data *ev = kdl_parser_next_event(parser);
		if (ev->event == KDL_EVENT_EOF)
			break;
		if (ev->event == KDL_EVENT_PARSE_ERROR)
		{
			fprintf(stderr, "parse error: %.*s\n", (int)ev->value.string.len, ev->value.string.data);
			exit(1);
		}
		if (ev->event == KDL_EVENT_START_NODE)
			nodes++;
	}
	kdl_destroy_parser(parser);
	return nodes;
}

static void op(void *p)
{
	ctx_t *c = p;
	c->nodes = parse_all(c);
}

int main(int argc, char **argv)
{
	if (argc < 4 || strcmp(argv[1], "parse") != 0)
	{
		fprintf(stderr, "usage: ckdl parse <file> <min-samples>\n");
		return argc >= 2 && strcmp(argv[1], "write") == 0 ? 3 : 2;
	}
	ctx_t c = {0};
	c.text = read_file(argv[2], &c.size);
	printf("nodes: %ld\n", parse_all(&c));
	print_result(measure(op, &c, atoi(argv[3])), c.size);
	return 0;
}
