// Java KDL benchmark: kdlbench <parse|write> <file> <min-samples>
// kdl4j: KdlParser.v2().parse(String) into its immutable document; write is KdlPrinter.printToString
// of the document parsed once. Prints the node count as a check line. Timings follow the shared rule
// (see measure and ../run.sh); the 1 s warm-up also lets the JIT compile the parser.
import dev.kdl.KdlDocument;
import dev.kdl.KdlNode;
import dev.kdl.parse.KdlParser;
import dev.kdl.print.KdlPrinter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class KdlBench {
	interface Op {
		void run() throws Exception;
	}

	/** Warm up for at least 1 s, then time single runs until at least minSamples were taken and at
	 * least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed. */
	static double[] measure(int minSamples, Op op) throws Exception {
		long warm = System.nanoTime();
		do
			op.run();
		while (System.nanoTime() - warm < 1_000_000_000L);
		long start = System.nanoTime();
		List<Double> samples = new ArrayList<>();
		while (true) {
			long t0 = System.nanoTime();
			op.run();
			samples.add((double) (System.nanoTime() - t0));
			List<Double> sorted = new ArrayList<>(samples);
			Collections.sort(sorted);
			int n = sorted.size();
			double median = n % 2 == 1 ? sorted.get(n / 2) : (sorted.get(n / 2 - 1) + sorted.get(n / 2)) / 2;
			if (n >= minSamples) {
				int within = 0;
				for (double s : samples)
					if (s >= median * 0.9 && s <= median * 1.1)
						within++;
				if (within >= 0.6 * n)
					return new double[] {median, n, 1};
			}
			if (n >= 1000 || System.nanoTime() - start >= 10_000_000_000L)
				return new double[] {median, n, 0};
		}
	}

	static long count(List<KdlNode> nodes) {
		long n = 0;
		for (KdlNode node : nodes)
			n += 1 + count(node.children());
		return n;
	}

	public static void main(String[] args) throws Exception {
		if (args.length < 3) {
			System.err.println("usage: kdlbench <parse|write> <file> <min-samples>");
			System.exit(2);
		}
		String text = Files.readString(Path.of(args[1]), StandardCharsets.UTF_8);
		int minSamples = Integer.parseInt(args[2]);
		KdlParser parser = KdlParser.v2();
		KdlDocument doc;
		try {
			doc = parser.parse(text);
		} catch (Exception e) {
			System.err.println("parse error: " + e.getMessage());
			System.exit(1);
			return;
		}
		System.out.println("nodes: " + count(doc.nodes()));
		long[] bytes = {text.getBytes(StandardCharsets.UTF_8).length};
		double[] m;
		if (args[0].equals("parse")) {
			m = measure(minSamples, () -> parser.parse(text));
		} else {
			KdlPrinter printer = new KdlPrinter();
			String[] out = {""};
			m = measure(minSamples, () -> out[0] = printer.printToString(doc));
			bytes[0] = out[0].getBytes(StandardCharsets.UTF_8).length;
		}
		double ms = m[0] / 1e6;
		System.out.printf("%.3f ms/op %.1f MB/s (n=%d, %s)%n", ms, bytes[0] / 1048576.0 / (ms / 1000.0), (int) m[1],
			m[2] == 1 ? "converged" : "capped");
	}
}
