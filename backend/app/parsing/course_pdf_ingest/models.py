from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class ParsedArtifacts:
    document_id: str
    source_path: Path
    output_dir: Path
    raw_document: dict[str, Any]
    normalized_document: dict[str, Any]
    metadata: dict[str, Any]
    markdown: str
    page_markdown: dict[int, str]
    section_markdown: dict[str, str]
