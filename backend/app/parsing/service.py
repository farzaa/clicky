from __future__ import annotations

import logging
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import urlparse

import httpx
from fastapi import HTTPException, status

from app.parsing.contracts import (
    ParseDocumentRequest,
    ParseDocumentResponse,
    TopicPageMarkdownFile,
)
from app.parsing.course_pdf_ingest.config import (
    BackendStrategy,
    OcrProvider,
    ParseConfig,
    ProfileName,
)
from app.parsing.course_pdf_ingest.pipeline import parse_topic
from app.parsing.course_pdf_ingest.utils import ensure_directory

parsing_logger = logging.getLogger("clicky.parsing")
default_output_root = Path(__file__).resolve().parent


async def parse_document_to_markdown(
    parse_document_request: ParseDocumentRequest,
) -> ParseDocumentResponse:
    source_document_path, temporary_download_path = await resolve_source_document_path(
        parse_document_request
    )
    try:
        parsing_result = parse_topic(
            source_path=source_document_path,
            topic=parse_document_request.topic,
            output_root=resolve_output_root_directory(parse_document_request),
            config=build_parse_config(parse_document_request),
            logger=parsing_logger,
            context_pages=parse_document_request.context_pages,
            toc_scan_limit=parse_document_request.toc_scan_limit,
            validation_window=parse_document_request.validation_window,
            source_document_kind=parse_document_request.source_document_kind,
        )
        return build_parse_response(
            parse_document_request=parse_document_request,
            parsing_result=parsing_result,
            source_document_path=source_document_path,
        )
    except HTTPException:
        raise
    except Exception as parsing_error:  # noqa: BLE001
        parsing_logger.exception("Failed to parse document topic.")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=(
                "Failed to parse document topic. "
                f"source='{source_document_path}' topic='{parse_document_request.topic}' "
                f"error='{parsing_error}'"
            ),
        ) from parsing_error
    finally:
        if temporary_download_path and temporary_download_path.exists():
            temporary_download_path.unlink(missing_ok=True)


def build_parse_config(parse_document_request: ParseDocumentRequest) -> ParseConfig:
    return ParseConfig.from_profile(
        profile=ProfileName(parse_document_request.parse_profile),
        backend=BackendStrategy(parse_document_request.backend_strategy),
        ocr_provider=OcrProvider(parse_document_request.ocr_provider),
        generate_page_images=False,
        generate_picture_images=True,
        enable_ocr=parse_document_request.enable_ocr,
        enable_code_enrichment=None,
        enable_formula_enrichment=None,
        continue_on_error=True,
        recursive=False,
        glob_pattern="*.pdf",
        output_root=resolve_output_root_directory(parse_document_request),
        ocr_langs=[],
        document_timeout=600.0,
        single_markdown_only=False,
    )


def resolve_output_root_directory(parse_document_request: ParseDocumentRequest) -> Path:
    if parse_document_request.output_root_directory:
        output_root_directory = Path(parse_document_request.output_root_directory).expanduser().resolve()
    else:
        output_root_directory = default_output_root
    ensure_directory(output_root_directory)
    return output_root_directory


async def resolve_source_document_path(
    parse_document_request: ParseDocumentRequest,
) -> tuple[Path, Path | None]:
    if parse_document_request.source_document_path:
        source_document_path = Path(parse_document_request.source_document_path).expanduser().resolve()
        if not source_document_path.exists():
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Source document path does not exist: {source_document_path}",
            )
        return source_document_path, None

    if parse_document_request.source_document_url:
        downloaded_path = await download_document_to_temporary_file(parse_document_request)
        return downloaded_path, downloaded_path

    raise HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        detail="Either source_document_path or source_document_url must be provided.",
    )


async def download_document_to_temporary_file(
    parse_document_request: ParseDocumentRequest,
) -> Path:
    source_document_url = parse_document_request.source_document_url or ""
    parsed_url = urlparse(source_document_url)
    inferred_suffix = Path(parsed_url.path).suffix or ".pdf"

    with NamedTemporaryFile(delete=False, suffix=inferred_suffix) as handle:
        temporary_file_path = Path(handle.name)

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as http_client:
            response = await http_client.get(source_document_url, follow_redirects=True)
            response.raise_for_status()
            temporary_file_path.write_bytes(response.content)
    except Exception as download_error:  # noqa: BLE001
        temporary_file_path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unable to download source_document_url: {download_error}",
        ) from download_error

    return temporary_file_path.resolve()


def build_parse_response(
    *,
    parse_document_request: ParseDocumentRequest,
    parsing_result: dict,
    source_document_path: Path,
) -> ParseDocumentResponse:
    status_value = parsing_result.get("status", "error")
    page_markdown_models = [
        TopicPageMarkdownFile(
            page_number=item.get("page_number", 0),
            path=item.get("path", ""),
        )
        for item in parsing_result.get("topic_page_markdown_paths", [])
        if isinstance(item, dict)
    ]
    return ParseDocumentResponse(
        status=status_value if status_value in {"success", "success_cached"} else "error",
        message=(
            "Topic markdown loaded from cache."
            if parsing_result.get("cache_hit")
            else "Topic markdown parsed successfully."
        ),
        source_document_identifier=parse_document_request.source_document_identifier,
        requested_output_format=parse_document_request.requested_output_format,
        topic=parsing_result.get("topic"),
        output_directory=parsing_result.get("output_dir"),
        topic_markdown_path=parsing_result.get("topic_markdown_path"),
        topic_page_markdown_paths=page_markdown_models,
        parsed_pdf_page_window=parsing_result.get("parsed_pdf_page_window"),
        resolved_pdf_page_number=parsing_result.get("resolved_pdf_page_number"),
        resolved_book_page_label=parsing_result.get("resolved_book_page_label"),
        matched_title=parsing_result.get("matched_title"),
        backend_used=parsing_result.get("backend_used"),
        warnings=parsing_result.get("warnings", []),
        cache_hit=bool(parsing_result.get("cache_hit")),
        source_document_path=str(source_document_path),
        source_document_kind=parse_document_request.source_document_kind,
        metadata={
            **parse_document_request.metadata,
            "user_id": parse_document_request.user_id,
            "course_id": parse_document_request.course_id,
        },
    )
