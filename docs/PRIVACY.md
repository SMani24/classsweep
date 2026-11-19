# Data handling

## Enrollment exception

The user explicitly submits an enrollment photograph to the local server for human review. The reviewer checks the student's identity through an appropriate independent source. A selfie by itself does not establish a university identity. The phone automatically creates the frontal reference from the exact approved image. Guided enrollment also creates two matching side templates locally. Only the front image is uploaded; the side images are discarded after capture and review.

The server stores enrollment images outside the public source tree, accessible only to the administrator and the image owner through authenticated endpoints. Delete images after the enrollment reference has been installed on the phone, according to the class's retention policy. Keep any necessary identity evidence outside this repository.

## Routine attendance

Camera frames, facial embeddings, OCR observations, and raw gyroscope samples stay on the phone. Only attendance identifiers and derived check outcomes/summary metrics are submitted. Classroom reference features are processed data but are not guaranteed anonymous; capture empty board regions and avoid people or sensitive writing.

Do not add frame upload, camera logging, analytics, or crash attachments containing images to attendance processing. Local enrollment capture files should be removed immediately after submission or cancellation.

## Transport

The instructor phone uses a revocable bearer session in Android secure storage. The password is entered at sign-in. The laptop dashboard uses HTTP Basic authentication and protects form writes with CSRF tokens.

Wi-Fi is the default: the launcher binds to the selected local Wi-Fi/Ethernet address and advertises `laptop.local` through Avahi for the server’s lifetime. The alias is a convenience name, not authentication. Optional `--local-only` plus USB `adb reverse` is still available. HTTP does not encrypt passwords, enrollment images, or attendance traffic. Use HTTPS before collecting real students' data on a shared network. Never expose this development server directly to the internet.

## Limits

This is an educational attendance aid. The server trusts derived results from the app. A modified client, sophisticated relay, or some screen replay attacks can bypass checks. Scores and thresholds are experimental and must be evaluated for false rejection and false acceptance. A missing sensor, unreadable board, accessibility need, or camera failure requires a manual attendance alternative.

No real enrollment images, biometric templates, credentials, or attendance records belong in the public GitHub repository or test fixtures.

## Optional location

GPS is disabled by default. When enabled for a session, the instructor explicitly captures their location as the classroom center; that center, accuracy, time and radius are stored on the laptop and shared with authenticated student phones for local distance calculation. Student raw coordinates stay on their phone. Only derived distance, accuracy and capture time are submitted; retained attendance data includes GPS status and optionally distance/accuracy, not student coordinates or capture timestamps. GPS-off sessions request no location permission or position. Location is sampled only in the foreground for a specific check, not tracked continuously. Disabling an open session stops further GPS requirements and drops subsequently supplied location summaries; it does not erase earlier records or the original instructor policy.
