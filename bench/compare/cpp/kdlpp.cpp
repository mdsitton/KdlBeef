// kdlpp benchmark (ckdl's C++ binding): kdlpp <parse|write> <file> <min-samples>
// parse: kdl::parse (KDL v2) into kdlpp's Document (vectors of nodes and arguments, properties in a
// sorted std::map). write: Document::to_string of the document parsed once. Prints the node count.
#include <kdlpp.h>
#include <string>
#include "../c/bench.h"

struct Ctx
{
	std::u8string_view text;
	const kdl::Document* doc;
	std::u8string output;
};

static long count(const std::vector<kdl::Node>& nodes)
{
	long n = 0;
	for (const auto& node : nodes)
		n += 1 + count(node.children());
	return n;
}

int main(int argc, char** argv)
{
	if (argc < 4) { std::fprintf(stderr, "usage: kdlpp <parse|write> <file> <min-samples>\n"); return 2; }
	const std::string mode = argv[1];
	long size = 0;
	char* data = read_file(argv[2], &size);
	std::u8string_view text(reinterpret_cast<const char8_t*>(data), size);
	kdl::Document doc;
	try
	{
		doc = kdl::parse(text, kdl::KdlVersion::Kdl_2);
	}
	catch (const std::exception& e)
	{
		std::fprintf(stderr, "parse error: %s\n", e.what());
		return 1;
	}
	std::printf("nodes: %ld\n", count(doc.nodes()));

	Ctx ctx{text, &doc, {}};
	if (mode == "parse")
	{
		print_result(measure([](void* p) {
			auto* c = static_cast<Ctx*>(p);
			kdl::Document d = kdl::parse(c->text, kdl::KdlVersion::Kdl_2);
			(void)d;
		}, &ctx, std::atoi(argv[3])), size);
		return 0;
	}
	measurement_t m = measure([](void* p) {
		auto* c = static_cast<Ctx*>(p);
		c->output = c->doc->to_string(kdl::KdlVersion::Kdl_2);
	}, &ctx, std::atoi(argv[3]));
	print_result(m, (long)ctx.output.size());
	return 0;
}
