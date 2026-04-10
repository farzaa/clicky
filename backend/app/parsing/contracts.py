from typing import Any, Literal

from pydantic import BaseModel, Field


class TopicPageMarkdownFile(BaseModel):
    page_number: int = Field(description="1-based PDF page number for this topic markdown file.")
    path: str = Field(description="Absolute path to the generated page markdown.")


class ParseDocumentRequest(BaseModel):
    source_document_path: str | None = Field(
        default=None,
        description="Absolute local path to the source PDF document.",
    )
    source_document_url: str | None = Field(
        default=None,
        description="Remote PDF or document URL to parse.",
    )
    source_file_name: str | None = Field(
        default=None,
        description="Original file name for display and downstream storage.",
    )
    source_document_identifier: str | None = Field(
        default=None,
        description="Caller-owned identifier used to correlate parsing jobs.",
    )
    topic: str = Field(
        description="Topic to locate and parse from the source document.",
        min_length=1,
    )
    source_document_kind: Literal["auto", "with_toc", "without_toc", "handwritten"] = Field(
        default="auto",
        description=(
            "Document routing mode. "
            "'with_toc' prefers TOC lookup, 'without_toc' prefers header chunking, "
            "'handwritten' forces Mistral OCR fallback for topic lookup."
        ),
    )
    output_root_directory: str | None = Field(
        default=None,
        description=(
            "Optional absolute directory where the '<file name> parsed' output folder is created."
        ),
    )
    context_pages: int = Field(
        default=0,
        ge=0,
        le=10,
        description="Requested pages before/after the resolved topic page.",
    )
    toc_scan_limit: int = Field(
        default=30,
        ge=1,
        le=200,
        description="How many leading pages to scan for printed TOC detection.",
    )
    validation_window: int = Field(
        default=6,
        ge=0,
        le=30,
        description="How many pages around the estimated page to validate local heading match.",
    )
    parse_profile: Literal["technical", "slides", "lightweight"] = Field(
        default="lightweight",
        description="Docling parse profile.",
    )
    backend_strategy: Literal["auto", "docling-parse", "pypdfium2"] = Field(
        default="auto",
        description="Docling backend strategy.",
    )
    ocr_provider: Literal["rapidocr", "olmocr", "glm-ocr", "mistral-ocr"] = Field(
        default="rapidocr",
        description="OCR provider used by OCR fallback and OCR-based topic matching.",
    )
    enable_ocr: bool = Field(
        default=True,
        description="Enable OCR in Docling pipeline options.",
    )
    requested_output_format: Literal["markdown"] = Field(
        default="markdown",
        description="The normalized output format that downstream consumers expect.",
    )
    user_id: str | None = Field(
        default=None,
        description="Optional application-level user identifier for ownership and auditing.",
    )
    course_id: str | None = Field(
        default=None,
        description="Optional course identifier if the parsed document belongs to a course.",
    )
    metadata: dict[str, Any] = Field(
        default_factory=dict,
        description="Arbitrary caller-provided metadata preserved for future parsing workflows.",
    )


class ParseDocumentResponse(BaseModel):
    status: Literal["success", "success_cached", "error"]
    message: str
    source_document_identifier: str | None = None
    requested_output_format: Literal["markdown"]
    topic: str | None = None
    output_directory: str | None = None
    topic_markdown_path: str | None = None
    topic_page_markdown_paths: list[TopicPageMarkdownFile] = Field(default_factory=list)
    parsed_pdf_page_window: list[int] | None = None
    resolved_pdf_page_number: int | None = None
    resolved_book_page_label: str | None = None
    matched_title: str | None = None
    backend_used: str | None = None
    warnings: list[str] = Field(default_factory=list)
    cache_hit: bool = False
    source_document_path: str | None = None
    source_document_kind: Literal["auto", "with_toc", "without_toc", "handwritten"] | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
