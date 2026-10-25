- There is no PR yet: the builder stopped before the no-mistakes gate, which runs once this review passes or its findings are fixed, and reviews the code line by line after you.
- Write your findings to `{{task_dir}}/review.md`, numbered, each with its file and line and one kind: `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`.
  Post nothing to GitHub: the re-review of the gate's PR posts the comment and sets the status.
- Send `{{task}} DONE pass {{head}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.
