# Upstream models

Run `python3 scripts/fetch_models.py` from the repository root before building.

The download manifest pins the OpenCV Zoo source commit, file lengths, and SHA-256 checksums. Model binaries are deliberately excluded from Git. Their upstream license texts are included alongside this file and must accompany distributed applications.

- YuNet: face detection and five facial landmarks, MIT license.
- SFace int8: aligned face embeddings, Apache License 2.0.

These are pretrained upstream models, not models trained by this project. Quantized-model runtime compatibility and face-verification thresholds must be tested on target devices.
