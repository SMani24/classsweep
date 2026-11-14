# Data handling

## Enrollment exception

The user explicitly submits an enrollment photograph to the local server for human review. The reviewer checks the student's identity through an appropriate independent source. A selfie by itself does not establish a university identity. The approved exact image is used to create the phone's local face reference; the app does not freely enroll a different face after approval.

The server stores enrollment images outside the public source tree, accessible only to the administrator and the image owner through authenticated endpoints. Delete images after the enrollment reference has been installed on the phone, according to the class's retention policy. Keep any necessary identity evidence outside this repository.

## Routine attendance

Camera frames, facial embeddings, OCR observations, and raw gyroscope samples stay on the phone. Only attendance identifiers and derived check outcomes/summary metrics are submitted. Classroom reference features are processed data but are not guaranteed anonymous; capture empty board regions and avoid people or sensitive writing.

Do not add frame upload, camera logging, analytics, or crash attachments containing images to attendance processing. Local enrollment capture files should be removed immediately after submission or cancellation.

## Transport

For a personal demonstration, prefer USB `adb reverse` to connect the phone to the server over localhost. The prototype also permits cleartext HTTP to a trusted local network for convenient classroom experiments. HTTP does not encrypt passwords, enrollment images, or attendance traffic. Use HTTPS before collecting real students' data on a shared network. Never expose this development server directly to the internet.

## Limits

This is an educational attendance aid. The server trusts derived results from the app. A modified client, sophisticated relay, or some screen replay attacks can bypass checks. Scores and thresholds are experimental and must be evaluated for false rejection and false acceptance. A missing sensor, unreadable board, accessibility need, or camera failure requires a manual attendance alternative.

No real enrollment images, biometric templates, credentials, or attendance records belong in the public GitHub repository or test fixtures.
