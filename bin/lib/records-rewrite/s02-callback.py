# The S02 story (projects/conventioner/backlog/E01-csv-vendor-intake/F04-real-export-shapes/, and
# backlog/... before T5 moved it) once quoted a real applicant's address; every version has any
# address not at example.com replaced by one. It holds no value itself.
if filename.endswith(b"F04-real-export-shapes/S02-a-timestamp-is-a-moment.md"):
    contents = value.get_contents_by_identifier(blob_id)
    cleaned = re.sub(
        rb"[A-Za-z0-9._%+-]+@(?!example\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
        b"vendor@example.com",
        contents,
    )
    if cleaned != contents:
        blob_id = value.insert_file_with_contents(cleaned)
return (filename, mode, blob_id)
