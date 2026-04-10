from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, is_dataclass
from datetime import UTC, datetime
from enum import Enum
from pathlib import Path
from typing import Any


def compute_file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_document_id(file_hash: str) -> str:
    return f"doc_{file_hash[:16]}"


def build_output_slug(filename: str, file_hash: str) -> str:
    return f"{slugify(Path(filename).stem)}-{file_hash[:12]}"


def slugify(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-").lower()
    return cleaned or "document"


def sanitize_filename_segment(value: str, max_length: int = 120) -> str:
    cleaned = re.sub(r"[\x00-\x1f<>:\"/\\|?*]+", " ", value)
    cleaned = re.sub(r"\s+", " ", cleaned).strip().rstrip(".")
    cleaned = cleaned[:max_length].strip()
    return cleaned


def build_parsed_output_directory_name(source_filename: str) -> str:
    source_stem = sanitize_filename_segment(Path(source_filename).stem, max_length=120)
    if not source_stem:
        source_stem = "document"
    return f"{source_stem} parsed"


def build_topic_markdown_filename(
    source_filename: str,
    topic: str,
    page_number: int | None = None,
) -> str:
    source_stem = sanitize_filename_segment(Path(source_filename).stem, max_length=90)
    if not source_stem:
        source_stem = "document"

    cleaned_topic = sanitize_filename_segment(topic, max_length=120)
    if not cleaned_topic:
        cleaned_topic = "topic"

    suffix = ""
    if page_number is not None:
        suffix = f" page {page_number}"
    return f"{source_stem} {cleaned_topic} markdown{suffix}.md"


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def ensure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(to_jsonable(payload), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def to_jsonable(value: Any) -> Any:
    if is_dataclass(value):
        return to_jsonable(asdict(value))
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {str(key): to_jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [to_jsonable(item) for item in value]
    if hasattr(value, "model_dump"):
        return to_jsonable(value.model_dump(mode="json"))
    if hasattr(value, "__dict__") and not isinstance(value, type):
        return to_jsonable(vars(value))
    return value


def safe_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()
