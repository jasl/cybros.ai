const reviews = params.paths.map((path, index) => {
  const source = g.tool({ name: "read_file", input: { path }, key: "source" + index });
  const review = g.model({ prompt: "Review " + path, results: [source], key: "review" + index });
  return [source, review];
});
g.parallel(reviews);
g.model({ prompt: "Combine the reviews.", results: reviews.map((chain) => chain[1]), key: "summary" });
