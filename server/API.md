# ClassSweep API v1 (mobile contract)

Base `http://HOST:8000`. JSON; times Unix seconds UTC; string IDs. Errors `{ "detail": "..." }`; schema errors 422. Student endpoints require `Authorization: Bearer TOKEN`. Admin uses HTTP Basic `admin:CLASSSWEEP_ADMIN_PASSWORD`. Admin writes additionally require `X-CSRF-Token` from authenticated `GET /admin/csrf` → `{ "csrf_token":"..." }`. No cookies. Use HTTPS outside trusted local development.

## Account / one-time enrollment

- `POST /api/register` `{username,password,display_name,device_id}` → 201 `{user,token,expires_at}`. Username 3–64 ASCII letters/digits/`_.-`; password 10–256 chars; display_name 1–100; device_id 8–128. Token TTL 7 days.
- `POST /api/login` `{username,password,device_id}` → same shape; device_id must match registration (403 otherwise). Device identity is client-asserted, not hardware attestation. `POST /api/logout` → 204.
- `GET /api/me` → `{id,username,display_name,device_id,enrollment_status,reference_sha256}`. Status `none|pending|approved|rejected`; hash null unless approved. Also `template_ready` and `image_available` booleans. `delete` means purge for approved enrollment; pending/rejected deletion resets enrollment. Revocation requires re-enrollment.
- `POST /api/enrollment` multipart `device_id` + `image` JPEG/PNG, ≤5 MiB, ≤16 million pixels, actual image decode required → 201 `{status:"pending",reference_sha256}`. Cannot replace pending/approved upload; rejection/revocation permits retry.
- `GET /api/enrollment/reference` → approved **original bytes**, headers `X-Reference-SHA256`, `X-Device-ID`, `Cache-Control: no-store`. 403 unless approved. Phone creates its local face template from these bytes; 410 if approved source bytes were subsequently purged. Hash is SHA-256 of exact uploaded/approved bytes. No routine attendance images, videos or face templates are accepted.

- `POST /api/enrollment/template-ready` `{device_id,reference_sha256}` → `{status:"ready"}` after local template has been persisted. This permits admin to purge the original image while preserving approval/hash/device binding. Do not acknowledge until template provisioning succeeds.

## Instructor room calibration (processed descriptors only)

- `POST /api/admin/classroom` (Basic + CSRF) replaces current room reference, JSON:

```json
{"name":"Room 101","views":[{"id":"front","width":1280,"height":720,"keypoints":[[120.5,230.0]],"descriptors":[[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31]]}]}
```

Shape example shows one point; real upload needs **8–2000 points per view**, 1–6 views; each descriptor exactly 32 integer bytes 0–255, one per keypoint. Coordinates finite and within view dimensions (1–8192). Unique view IDs. Only these fields allowed; ≤4 MiB JSON. Upload ORB keypoint positions/descriptors computed on instructor phone, **never room photos**. Response 201 `{id,name,views,created_at}`. Older versions remain available to sessions pinned to them.
- `GET /api/classroom` (student bearer) → current `{id,name,views,created_at}`, 404 before calibration. Optional `?reference_id=ID` retrieves session's pinned version. Phone downloads this processed reference for local room matching.

## Sessions / attempts / results

- `POST /admin/sessions` (Basic + CSRF) `{title,ttl_seconds:300}` → 201 `{id,title,code_a,code_b,expires_at,classroom_reference_id}`. TTL 30–1800 seconds. Requires room calibration. Both fresh four-digit codes shown in dashboard `/admin`.
- `GET /api/sessions` → active array `{id,title,expires_at,classroom_reference_id}` (no codes).
- `POST /api/attempts` student JSON `{session_id,code_a,code_b,device_id,reference_sha256}` → 201 `{attempt_id,session_id,direction:"left"|"right",instruction,expires_at,classroom_reference_id}`. Two valid OCR-collected codes required; A/B order may be reversed. Both must belong to selected session_id. Phone fetches pinned classroom reference if needed. Random turn **then return to center** instruction; TTL 90 seconds capped by session expiry. New attempt invalidates prior active attempt for this user/session.
- `POST /api/attendance` exact JSON below → 201 `{id,session_id,recorded_at}`:

```json
{
  "attempt_id":"...",
  "device_id":"...",
  "reference_sha256":"64-lowercase-hex-approved-image-hash",
  "classroom_reference_id":"from-attempt-response",
  "direction":"left",
  "checks":{"face_match":true,"single_face":true,"turn_completed":true,"returned_to_center":true,"continuous_face":true,"liveness_passed":true,"room_match":true,"rear_camera_scan":true,"rear_camera_recheck":true,"motion_correlated":true},
  "metrics":{"match_distance":0.35,"max_yaw_degrees":24.0,"return_yaw_degrees":2.0,"duration_ms":3200.0,"room_good_matches":24,"room_inlier_ratio":0.8,"room_recheck_good_matches":22,"room_recheck_inlier_ratio":0.75,"motion_correlation":0.9}
}
```

All checks must be literal booleans and all true; unknown fields rejected. All metrics finite numbers: match_distance 0–10; max_yaw_degrees 0–180; return_yaw_degrees -180–180; duration_ms >0–90000; room_good_matches and room_recheck_good_matches integers 8–12000; room_inlier_ratio and room_recheck_inlier_ratio >0–1; motion_correlation -1–1. Rear scan before front challenge and rear recheck afterwards must both pass locally; motion correlation is a client measurement. Client implements and thresholds actual vision; server validates claims/bindings and does not independently verify biometric/liveness/room evidence. Direction, enrolled device, approved image hash, and session's classroom ID must match. Structurally valid owner submission consumes attempt even on failed checks/binding; invalid schema does not. Replay/duplicate 409; expired 410; failed bindings/checks 403; unknown/other user's attempt 404. Atomic unique attendance per user/session.
- `GET /api/attendance` → own array `{id,session_id,title,recorded_at}`.

## Web admin

`GET /admin` authenticated dashboard: review original enrollment images, approve/reject/purge/revoke. Purge only after phone template provisioning; it removes image bytes while preserving approved status/hash/device and valid attempts. Revoke clears approval and invalidates attempts, create sessions, display both codes, download CSV. Pending image: `GET /admin/enrollments/{user_id}/image`. Mutations `POST /admin/enrollments/{user_id}/approve|reject|delete|revoke` with CSRF form field `csrf_token` (or header); `GET /admin/sessions/{id}/results.csv`. `GET /admin/sessions` lists sessions. No default password; startup requires `CLASSSWEEP_ADMIN_PASSWORD`. Storage `CLASSSWEEP_DATA_DIR`.
