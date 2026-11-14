# ClassSweep

An Android-first, privacy-conscious classroom attendance prototype for an Introduction to Computer Vision course.

Students scan fresh handwritten codes on opposite sides of a classroom board, follow a short motion challenge, and verify their face against a human-approved enrollment reference. Routine camera frames and motion measurements are processed on the phone.

## Scope

- Android Flutter application; Linux FastAPI/SQLite server.
- One-time enrollment image submission for human review is an explicit exception to local-only image processing.
- Local face verification, board OCR, natural-feature matching, and camera/gyroscope consistency.
- No markers, projector, cloud inference, or model training.
- Educational prototype: checks deter casual sharing and replay; they do not establish tamper-proof physical presence.
- iOS is deferred. No iOS build or device testing is claimed.

## Development

Implementation and device verification are in progress. Setup commands and tested status will be added as components are integrated.

Do not commit enrollment images, face templates, attendance records, credentials, or local databases. Model weights are downloaded separately from their upstream source.
