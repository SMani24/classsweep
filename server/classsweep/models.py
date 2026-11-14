from typing import Annotated, Literal
import math

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, field_validator, model_validator


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


Device = Annotated[str, Field(min_length=8, max_length=128)]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
Identifier = Annotated[str, Field(min_length=1, max_length=128)]


class Register(Model):
    username: Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]{3,64}$")]
    password: Annotated[str, Field(min_length=10, max_length=256)]
    display_name: Annotated[str, Field(min_length=1, max_length=100)]
    device_id: Device

    @field_validator("display_name")
    @classmethod
    def name_not_blank(cls, value):
        if not value.strip():
            raise ValueError("display_name must not be blank")
        return value


class Login(Model):
    device_id: Device
    username: Annotated[str, Field(min_length=1, max_length=64)]
    password: Annotated[str, Field(min_length=1, max_length=256)]


class SessionCreate(Model):
    title: Annotated[str, Field(min_length=1, max_length=150)]
    ttl_seconds: Annotated[StrictInt, Field(ge=30, le=1800)] = 300

    @field_validator("title")
    @classmethod
    def title_not_blank(cls, value):
        if not value.strip():
            raise ValueError("title must not be blank")
        return value


class AttemptCreate(Model):
    session_id: Identifier
    code_a: Annotated[str, Field(pattern=r"^[0-9]{4}$")]
    code_b: Annotated[str, Field(pattern=r"^[0-9]{4}$")]
    device_id: Device
    reference_sha256: Digest


class Checks(Model):
    face_match: StrictBool
    single_face: StrictBool
    turn_completed: StrictBool
    returned_to_center: StrictBool
    continuous_face: StrictBool
    liveness_passed: StrictBool
    room_match: StrictBool
    rear_camera_scan: StrictBool
    rear_camera_recheck: StrictBool
    motion_correlated: StrictBool


class Metrics(Model):
    match_distance: Annotated[float, Field(ge=0, le=10)]
    max_yaw_degrees: Annotated[float, Field(ge=0, le=180)]
    return_yaw_degrees: Annotated[float, Field(ge=-180, le=180)]
    duration_ms: Annotated[float, Field(gt=0, le=90000)]
    room_good_matches: Annotated[StrictInt, Field(ge=8, le=12000)]
    room_inlier_ratio: Annotated[float, Field(gt=0, le=1)]
    room_recheck_good_matches: Annotated[StrictInt, Field(ge=8, le=12000)]
    room_recheck_inlier_ratio: Annotated[float, Field(gt=0, le=1)]
    motion_correlation: Annotated[float, Field(ge=-1, le=1)]


class AttendanceCreate(Model):
    attempt_id: Identifier
    device_id: Device
    reference_sha256: Digest
    classroom_reference_id: Identifier
    direction: Literal["left", "right"]
    checks: Checks
    metrics: Metrics


class View(Model):
    id: Annotated[str, Field(min_length=1, max_length=64)]
    width: Annotated[StrictInt, Field(ge=1, le=8192)]
    height: Annotated[StrictInt, Field(ge=1, le=8192)]
    keypoints: Annotated[list[list[float]], Field(min_length=8, max_length=2000)]
    descriptors: Annotated[list[list[StrictInt]], Field(min_length=8, max_length=2000)]

    @model_validator(mode="after")
    def valid_orb(self):
        if len(self.keypoints) != len(self.descriptors):
            raise ValueError("one descriptor required for each keypoint")
        for point in self.keypoints:
            if (len(point) != 2 or not all(math.isfinite(v) for v in point)
                    or not 0 <= point[0] < self.width or not 0 <= point[1] < self.height):
                raise ValueError("keypoints must be finite [x,y] inside view")
        for row in self.descriptors:
            if len(row) != 32 or any(not 0 <= value <= 255 for value in row):
                raise ValueError("ORB descriptors must have exactly 32 integer bytes")
        return self


class ClassroomCreate(Model):
    name: Annotated[str, Field(min_length=1, max_length=100)]
    views: Annotated[list[View], Field(min_length=1, max_length=6)]

    @model_validator(mode="after")
    def unique_views(self):
        if not self.name.strip():
            raise ValueError("name must not be blank")
        if len({view.id for view in self.views}) != len(self.views):
            raise ValueError("view IDs must be unique")
        return self


class TemplateReady(Model):
    device_id: Device
    reference_sha256: Digest
