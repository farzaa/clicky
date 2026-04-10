from typing import Any, Literal

from pydantic import BaseModel, Field


class ParseDocumentRequest(BaseModel):
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
    status: Literal["placeholder"]
    message: str
    source_document_identifier: str | None = None
    requested_output_format: Literal["markdown"]
