from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import mimetypes
from datetime import UTC, datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models import (
    WorkspaceContentType,
    WorkspaceEntry,
    WorkspaceEntryType,
    WorkspaceIngestionJob,
    WorkspaceIngestionJobStatus,
)
from app.parsing.course_pdf_ingest.config import (
    BackendStrategy,
    OcrProvider,
    ParseConfig,
    ProfileName,
)
from app.parsing.course_pdf_ingest.pipeline import parse_file

workspace_ingestion_logger = logging.getLogger("clicky.workspace_ingestion")


def build_ingestion_bundle_directory_path(source_entry_path: str) -> str:
    parent_directory_path = source_entry_path.rsplit("/", 1)[0] or "/"
    source_filename = source_entry_path.rsplit("/", 1)[-1]
    source_stem = Path(source_filename).stem or source_filename or "document"
    bundle_directory_name = f"{source_stem}__ingested"
    if parent_directory_path == "/":
        return f"/{bundle_directory_name}"
    return f"{parent_directory_path}/{bundle_directory_name}"


def schedule_workspace_ingestion_job(
    *,
    database_session_factory: async_sessionmaker[AsyncSession],
    ingestion_job_id: UUID,
) -> None:
    ingestion_task = asyncio.create_task(
        run_workspace_ingestion_job(
            database_session_factory=database_session_factory,
            ingestion_job_id=ingestion_job_id,
        )
    )
    ingestion_task.add_done_callback(_log_background_ingestion_failure)


async def run_workspace_ingestion_job(
    *,
    database_session_factory: async_sessionmaker[AsyncSession],
    ingestion_job_id: UUID,
) -> None:
    try:
        source_file_name, source_entry_path, source_file_bytes = await _start_workspace_ingestion_job(
            database_session_factory=database_session_factory,
            ingestion_job_id=ingestion_job_id,
        )
        with TemporaryDirectory(prefix="workspace-ingestion-") as temporary_directory:
            parse_result, output_directory_path = await _parse_workspace_source_file(
                source_file_name=source_file_name,
                source_file_bytes=source_file_bytes,
                source_entry_path=source_entry_path,
                working_directory_path=Path(temporary_directory),
            )
            await _persist_workspace_ingestion_outputs(
                database_session_factory=database_session_factory,
                ingestion_job_id=ingestion_job_id,
                output_directory_path=output_directory_path,
                parse_result=parse_result,
                source_entry_path=source_entry_path,
                source_file_name=source_file_name,
                source_file_bytes=source_file_bytes,
            )
    except Exception as ingestion_error:  # noqa: BLE001
        workspace_ingestion_logger.exception(
            "Workspace ingestion failed for job %s.",
            ingestion_job_id,
        )
        await _mark_workspace_ingestion_job_failed(
            database_session_factory=database_session_factory,
            ingestion_job_id=ingestion_job_id,
            error_message=str(ingestion_error),
        )


async def _start_workspace_ingestion_job(
    *,
    database_session_factory: async_sessionmaker[AsyncSession],
    ingestion_job_id: UUID,
) -> tuple[str, str, bytes]:
    async with database_session_factory() as database_session:
        workspace_ingestion_job = await database_session.get(
            WorkspaceIngestionJob,
            ingestion_job_id,
        )
        if workspace_ingestion_job is None:
            raise RuntimeError(f"Ingestion job `{ingestion_job_id}` was not found.")

        source_workspace_entry = await database_session.get(
            WorkspaceEntry,
            workspace_ingestion_job.source_entry_id,
        )
        if source_workspace_entry is None:
            raise RuntimeError("Ingestion source entry is missing.")
        if source_workspace_entry.entry_type != WorkspaceEntryType.file:
            raise RuntimeError("Ingestion source entry must be a file.")
        if source_workspace_entry.content_type != WorkspaceContentType.pdf:
            raise RuntimeError("Ingestion source entry must be a PDF file.")

        source_file_bytes = _extract_workspace_entry_bytes(source_workspace_entry)
        if not source_file_bytes:
            raise RuntimeError("Ingestion source PDF has empty content.")

        workspace_ingestion_job.status = WorkspaceIngestionJobStatus.running
        workspace_ingestion_job.started_at = datetime.now(UTC)
        workspace_ingestion_job.completed_at = None
        workspace_ingestion_job.status_message = "Parsing PDF and building workspace bundle."

        source_entry_metadata = _ensure_metadata_dict(source_workspace_entry.entry_metadata)
        source_entry_metadata["ingestion"] = {
            "job_id": str(workspace_ingestion_job.id),
            "status": WorkspaceIngestionJobStatus.running.value,
            "source_entry_path": source_workspace_entry.entry_path,
            "bundle_directory_path": build_ingestion_bundle_directory_path(
                source_workspace_entry.entry_path
            ),
            "updated_at": datetime.now(UTC).isoformat(),
        }
        source_workspace_entry.entry_metadata = source_entry_metadata

        await database_session.commit()
        return (
            source_workspace_entry.entry_name,
            source_workspace_entry.entry_path,
            source_file_bytes,
        )


async def _parse_workspace_source_file(
    *,
    source_file_name: str,
    source_file_bytes: bytes,
    source_entry_path: str,
    working_directory_path: Path,
) -> tuple[dict, Path]:
    source_file_path = working_directory_path / source_file_name
    source_file_path.write_bytes(source_file_bytes)

    output_root_directory_path = working_directory_path / "parsed"
    output_root_directory_path.mkdir(parents=True, exist_ok=True)
    parse_config = ParseConfig.from_profile(
        profile=ProfileName.LIGHTWEIGHT,
        backend=BackendStrategy.AUTO,
        ocr_provider=OcrProvider.RAPIDOCR,
        generate_page_images=False,
        generate_picture_images=True,
        enable_ocr=False,
        enable_code_enrichment=False,
        enable_formula_enrichment=False,
        continue_on_error=True,
        recursive=False,
        glob_pattern="*.pdf",
        output_root=output_root_directory_path,
        ocr_langs=[],
        document_timeout=600.0,
        single_markdown_only=False,
    )

    parse_result = await asyncio.to_thread(
        parse_file,
        source_path=source_file_path,
        output_root=output_root_directory_path,
        config=parse_config,
        logger=workspace_ingestion_logger,
    )
    output_directory_path = Path(str(parse_result.get("output_dir", ""))).resolve()
    if not output_directory_path.exists():
        raise RuntimeError("Parser did not produce an output directory.")

    normalized_document_path = output_directory_path / "normalized" / "document.json"
    if not normalized_document_path.exists():
        raise RuntimeError("Parser output is missing normalized/document.json.")
    normalized_document = json.loads(normalized_document_path.read_text(encoding="utf-8"))
    toc_path = output_directory_path / "toc.json"
    toc_path.write_text(
        json.dumps(normalized_document.get("toc", []), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    page_index_path = output_directory_path / "page_index.jsonl"
    page_index_path.write_text(
        build_page_index_jsonl(
            normalized_document=normalized_document,
            source_entry_path=source_entry_path,
        ),
        encoding="utf-8",
    )
    return parse_result, output_directory_path


async def _persist_workspace_ingestion_outputs(
    *,
    database_session_factory: async_sessionmaker[AsyncSession],
    ingestion_job_id: UUID,
    output_directory_path: Path,
    parse_result: dict,
    source_entry_path: str,
    source_file_name: str,
    source_file_bytes: bytes,
) -> None:
    async with database_session_factory() as database_session:
        workspace_ingestion_job = await database_session.get(
            WorkspaceIngestionJob,
            ingestion_job_id,
        )
        if workspace_ingestion_job is None:
            raise RuntimeError(f"Ingestion job `{ingestion_job_id}` was not found.")

        source_workspace_entry = await database_session.get(
            WorkspaceEntry,
            workspace_ingestion_job.source_entry_id,
        )
        if source_workspace_entry is None:
            raise RuntimeError("Ingestion source entry is missing.")

        bundle_directory_path = build_ingestion_bundle_directory_path(
            workspace_ingestion_job.source_entry_path
        )
        all_workspace_entries = await _load_workspace_entries_for_workspace(
            database_session=database_session,
            workspace_id=workspace_ingestion_job.workspace_id,
        )
        workspace_entries_by_path = {
            workspace_entry.entry_path: workspace_entry
            for workspace_entry in all_workspace_entries
        }
        await _delete_existing_bundle_entries(
            database_session=database_session,
            workspace_entries_by_path=workspace_entries_by_path,
            bundle_directory_path=bundle_directory_path,
        )
        await _upsert_workspace_directory(
            database_session=database_session,
            workspace_entries_by_path=workspace_entries_by_path,
            workspace_id=workspace_ingestion_job.workspace_id,
            created_by_user_id=workspace_ingestion_job.created_by_user_id,
            directory_path=bundle_directory_path,
            entry_metadata={
                "kind": "parsed_document_bundle",
                "source_entry_path": source_workspace_entry.entry_path,
                "ingestion_job_id": str(workspace_ingestion_job.id),
            },
        )

        source_file_bundle_path = f"{bundle_directory_path}/source.pdf"
        await _upsert_workspace_file(
            database_session=database_session,
            workspace_entries_by_path=workspace_entries_by_path,
            workspace_id=workspace_ingestion_job.workspace_id,
            created_by_user_id=workspace_ingestion_job.created_by_user_id,
            file_path=source_file_bundle_path,
            file_bytes=source_file_bytes,
            entry_metadata={
                "kind": "source_document",
                "source_entry_path": source_workspace_entry.entry_path,
            },
        )

        normalized_document_path = output_directory_path / "normalized" / "document.json"
        normalized_document = json.loads(normalized_document_path.read_text(encoding="utf-8"))
        manifest_payload = build_ingestion_manifest_payload(
            workspace_ingestion_job=workspace_ingestion_job,
            source_workspace_entry=source_workspace_entry,
            source_file_name=source_file_name,
            source_file_bytes=source_file_bytes,
            parse_result=parse_result,
            source_entry_path=source_entry_path,
            bundle_directory_path=bundle_directory_path,
            normalized_document=normalized_document,
        )
        (output_directory_path / "manifest.json").write_text(
            json.dumps(manifest_payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        for local_file_path in sorted(output_directory_path.rglob("*")):
            if not local_file_path.is_file():
                continue
            relative_file_path = local_file_path.relative_to(output_directory_path).as_posix()
            workspace_file_path = f"{bundle_directory_path}/{relative_file_path}"
            await _upsert_workspace_file(
                database_session=database_session,
                workspace_entries_by_path=workspace_entries_by_path,
                workspace_id=workspace_ingestion_job.workspace_id,
                created_by_user_id=workspace_ingestion_job.created_by_user_id,
                file_path=workspace_file_path,
                file_bytes=local_file_path.read_bytes(),
                entry_metadata={
                    "kind": "parsed_document_artifact",
                    "source_entry_path": source_workspace_entry.entry_path,
                    "ingestion_job_id": str(workspace_ingestion_job.id),
                },
            )

        workspace_ingestion_job.status = WorkspaceIngestionJobStatus.completed
        workspace_ingestion_job.status_message = "Workspace ingestion completed."
        workspace_ingestion_job.completed_at = datetime.now(UTC)
        workspace_ingestion_job.output_bundle_path = bundle_directory_path
        workspace_ingestion_job.job_metadata = {
            **_ensure_metadata_dict(workspace_ingestion_job.job_metadata),
            "parse_result": parse_result,
            "bundle_directory_path": bundle_directory_path,
        }

        source_entry_metadata = _ensure_metadata_dict(source_workspace_entry.entry_metadata)
        source_entry_metadata["ingestion"] = {
            "job_id": str(workspace_ingestion_job.id),
            "status": WorkspaceIngestionJobStatus.completed.value,
            "source_entry_path": source_workspace_entry.entry_path,
            "bundle_directory_path": bundle_directory_path,
            "updated_at": datetime.now(UTC).isoformat(),
        }
        source_workspace_entry.entry_metadata = source_entry_metadata

        await database_session.commit()


async def _mark_workspace_ingestion_job_failed(
    *,
    database_session_factory: async_sessionmaker[AsyncSession],
    ingestion_job_id: UUID,
    error_message: str,
) -> None:
    async with database_session_factory() as database_session:
        workspace_ingestion_job = await database_session.get(
            WorkspaceIngestionJob,
            ingestion_job_id,
        )
        if workspace_ingestion_job is None:
            return

        source_workspace_entry = await database_session.get(
            WorkspaceEntry,
            workspace_ingestion_job.source_entry_id,
        )

        workspace_ingestion_job.status = WorkspaceIngestionJobStatus.failed
        workspace_ingestion_job.status_message = error_message[:4000]
        workspace_ingestion_job.completed_at = datetime.now(UTC)

        if source_workspace_entry is not None:
            source_entry_metadata = _ensure_metadata_dict(source_workspace_entry.entry_metadata)
            source_entry_metadata["ingestion"] = {
                "job_id": str(workspace_ingestion_job.id),
                "status": WorkspaceIngestionJobStatus.failed.value,
                "source_entry_path": source_workspace_entry.entry_path,
                "bundle_directory_path": build_ingestion_bundle_directory_path(
                    source_workspace_entry.entry_path
                ),
                "error": error_message[:1000],
                "updated_at": datetime.now(UTC).isoformat(),
            }
            source_workspace_entry.entry_metadata = source_entry_metadata

        await database_session.commit()


def build_page_index_jsonl(
    *,
    normalized_document: dict,
    source_entry_path: str,
) -> str:
    sections_by_id = {
        str(section.get("section_id")): section
        for section in normalized_document.get("sections", [])
        if isinstance(section, dict)
    }
    page_index_lines: list[str] = []
    for page in normalized_document.get("pages", []):
        if not isinstance(page, dict):
            continue
        section_ids = page.get("section_ids") or []
        heading_path: list[str] = []
        if isinstance(section_ids, list) and section_ids:
            first_section = sections_by_id.get(str(section_ids[0]))
            if isinstance(first_section, dict):
                maybe_heading_path = first_section.get("heading_path")
                if isinstance(maybe_heading_path, list):
                    heading_path = [str(item) for item in maybe_heading_path if isinstance(item, str)]
        page_text = str(page.get("text") or "")
        page_summary = summarize_page_text(page_text)
        page_index_lines.append(
            json.dumps(
                {
                    "page_number": page.get("page_number"),
                    "page_index": page.get("page_index"),
                    "book_page_label": page.get("book_page_label"),
                    "heading_path": heading_path,
                    "summary": page_summary,
                    "text": page_text,
                    "source_entry_path": source_entry_path,
                },
                ensure_ascii=False,
            )
        )

    if not page_index_lines:
        return ""
    return "\n".join(page_index_lines) + "\n"


def summarize_page_text(page_text: str) -> str:
    collapsed_page_text = " ".join(page_text.split())
    if len(collapsed_page_text) <= 220:
        return collapsed_page_text
    return collapsed_page_text[:220].rstrip() + "..."


def build_ingestion_manifest_payload(
    *,
    workspace_ingestion_job: WorkspaceIngestionJob,
    source_workspace_entry: WorkspaceEntry,
    source_file_name: str,
    source_file_bytes: bytes,
    parse_result: dict,
    source_entry_path: str,
    bundle_directory_path: str,
    normalized_document: dict,
) -> dict:
    processing = normalized_document.get("processing", {})
    document = normalized_document.get("document", {})
    return {
        "schema_version": "1.0",
        "ingestion_job_id": str(workspace_ingestion_job.id),
        "workspace_id": str(workspace_ingestion_job.workspace_id),
        "generated_at": datetime.now(UTC).isoformat(),
        "source": {
            "entry_id": str(source_workspace_entry.id),
            "entry_path": source_workspace_entry.entry_path,
            "entry_name": source_file_name,
            "sha256": hashlib.sha256(source_file_bytes).hexdigest(),
        },
        "bundle_directory_path": bundle_directory_path,
        "parser": {
            "status": parse_result.get("status"),
            "backend_used": parse_result.get("backend_used"),
            "page_count": parse_result.get("page_count"),
            "section_count": parse_result.get("section_count"),
            "block_count": parse_result.get("block_count"),
            "warnings": parse_result.get("warnings", []),
            "source_entry_path": source_entry_path,
            "document_id": document.get("document_id"),
            "profile": processing.get("profile"),
        },
        "artifacts": {
            "source_pdf": "source.pdf",
            "toc": "toc.json",
            "page_index": "page_index.jsonl",
            "normalized_document": "normalized/document.json",
            "agent_markdown": "exports/document.agent.md",
            "document_markdown": "exports/document.md",
        },
    }


def _extract_workspace_entry_bytes(source_workspace_entry: WorkspaceEntry) -> bytes:
    if source_workspace_entry.binary_content is not None:
        return source_workspace_entry.binary_content
    if source_workspace_entry.text_content is not None:
        return source_workspace_entry.text_content.encode("utf-8")
    return b""


async def _load_workspace_entries_for_workspace(
    *,
    database_session: AsyncSession,
    workspace_id: UUID,
) -> list[WorkspaceEntry]:
    workspace_entries_query = (
        select(WorkspaceEntry)
        .where(WorkspaceEntry.workspace_id == workspace_id)
        .order_by(WorkspaceEntry.entry_path.asc())
    )
    return list((await database_session.execute(workspace_entries_query)).scalars().all())


async def _delete_existing_bundle_entries(
    *,
    database_session: AsyncSession,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
    bundle_directory_path: str,
) -> None:
    bundle_entry_paths = [
        entry_path
        for entry_path in workspace_entries_by_path
        if entry_path == bundle_directory_path or entry_path.startswith(f"{bundle_directory_path}/")
    ]
    bundle_entry_paths.sort(key=_workspace_path_depth, reverse=True)
    for entry_path in bundle_entry_paths:
        workspace_entry = workspace_entries_by_path.pop(entry_path)
        await database_session.delete(workspace_entry)
    await database_session.flush()


async def _upsert_workspace_directory(
    *,
    database_session: AsyncSession,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
    workspace_id: UUID,
    created_by_user_id: UUID | None,
    directory_path: str,
    entry_metadata: dict,
) -> WorkspaceEntry:
    normalized_directory_path = normalize_workspace_entry_path(directory_path)
    if normalized_directory_path == "/":
        root_workspace_entry = workspace_entries_by_path.get("/")
        if root_workspace_entry is None:
            raise RuntimeError("Workspace root directory is missing.")
        return root_workspace_entry

    current_workspace_path = ""
    current_workspace_entry = workspace_entries_by_path.get("/")
    if current_workspace_entry is None:
        raise RuntimeError("Workspace root directory is missing.")

    for path_component in normalized_directory_path.strip("/").split("/"):
        current_workspace_path = f"{current_workspace_path}/{path_component}"
        existing_workspace_entry = workspace_entries_by_path.get(current_workspace_path)
        if existing_workspace_entry is None:
            existing_workspace_entry = WorkspaceEntry(
                workspace_id=workspace_id,
                parent_entry_id=current_workspace_entry.id,
                created_by_user_id=created_by_user_id,
                entry_name=path_component,
                entry_path=current_workspace_path,
                entry_type=WorkspaceEntryType.directory,
                entry_metadata=entry_metadata if current_workspace_path == normalized_directory_path else {},
            )
            database_session.add(existing_workspace_entry)
            await database_session.flush()
            workspace_entries_by_path[current_workspace_path] = existing_workspace_entry
        elif existing_workspace_entry.entry_type != WorkspaceEntryType.directory:
            raise RuntimeError(
                f"Workspace entry `{current_workspace_path}` already exists and is not a directory."
            )
        elif current_workspace_path == normalized_directory_path:
            existing_workspace_entry.entry_metadata = entry_metadata

        current_workspace_entry = existing_workspace_entry

    return current_workspace_entry


async def _upsert_workspace_file(
    *,
    database_session: AsyncSession,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
    workspace_id: UUID,
    created_by_user_id: UUID | None,
    file_path: str,
    file_bytes: bytes,
    entry_metadata: dict,
) -> WorkspaceEntry:
    normalized_file_path = normalize_workspace_entry_path(file_path)
    parent_directory_path = normalized_file_path.rsplit("/", 1)[0] or "/"
    parent_workspace_entry = await _upsert_workspace_directory(
        database_session=database_session,
        workspace_entries_by_path=workspace_entries_by_path,
        workspace_id=workspace_id,
        created_by_user_id=created_by_user_id,
        directory_path=parent_directory_path,
        entry_metadata={},
    )

    existing_workspace_entry = workspace_entries_by_path.get(normalized_file_path)
    if existing_workspace_entry is not None and existing_workspace_entry.entry_type != WorkspaceEntryType.file:
        raise RuntimeError(f"Workspace entry `{normalized_file_path}` is not a file.")

    inferred_content_type, inferred_mime_type, text_content, binary_content = (
        infer_workspace_file_storage(
            file_path=normalized_file_path,
            file_bytes=file_bytes,
        )
    )
    file_sha256 = hashlib.sha256(file_bytes).hexdigest()
    file_name = normalized_file_path.rsplit("/", 1)[-1]

    if existing_workspace_entry is None:
        existing_workspace_entry = WorkspaceEntry(
            workspace_id=workspace_id,
            parent_entry_id=parent_workspace_entry.id,
            created_by_user_id=created_by_user_id,
            entry_name=file_name,
            entry_path=normalized_file_path,
            entry_type=WorkspaceEntryType.file,
            content_type=inferred_content_type,
            mime_type=inferred_mime_type,
            size_bytes=len(file_bytes),
            content_sha256=file_sha256,
            text_content=text_content,
            binary_content=binary_content,
            entry_metadata=entry_metadata,
        )
        database_session.add(existing_workspace_entry)
        await database_session.flush()
        workspace_entries_by_path[normalized_file_path] = existing_workspace_entry
        return existing_workspace_entry

    existing_workspace_entry.parent_entry_id = parent_workspace_entry.id
    existing_workspace_entry.created_by_user_id = created_by_user_id
    existing_workspace_entry.entry_name = file_name
    existing_workspace_entry.entry_type = WorkspaceEntryType.file
    existing_workspace_entry.content_type = inferred_content_type
    existing_workspace_entry.mime_type = inferred_mime_type
    existing_workspace_entry.size_bytes = len(file_bytes)
    existing_workspace_entry.content_sha256 = file_sha256
    existing_workspace_entry.text_content = text_content
    existing_workspace_entry.binary_content = binary_content
    existing_workspace_entry.storage_object_key = None
    existing_workspace_entry.entry_metadata = entry_metadata
    return existing_workspace_entry


def infer_workspace_file_storage(
    *,
    file_path: str,
    file_bytes: bytes,
) -> tuple[WorkspaceContentType, str | None, str | None, bytes | None]:
    inferred_mime_type = mimetypes.guess_type(file_path)[0]
    try:
        text_content = file_bytes.decode("utf-8")
        is_utf8_text = True
    except UnicodeDecodeError:
        text_content = None
        is_utf8_text = False

    if is_utf8_text:
        if file_path.endswith(".md") or file_path.endswith(".markdown"):
            return WorkspaceContentType.markdown, inferred_mime_type or "text/markdown", text_content, None
        return WorkspaceContentType.text, inferred_mime_type or "text/plain", text_content, None

    if inferred_mime_type == "application/pdf" or file_path.endswith(".pdf"):
        return WorkspaceContentType.pdf, inferred_mime_type or "application/pdf", None, file_bytes
    if inferred_mime_type and inferred_mime_type.startswith("image/"):
        return WorkspaceContentType.image, inferred_mime_type, None, file_bytes
    return WorkspaceContentType.other, inferred_mime_type, None, file_bytes


def normalize_workspace_entry_path(entry_path: str) -> str:
    trimmed_entry_path = entry_path.strip()
    if not trimmed_entry_path:
        raise RuntimeError("Workspace path must be non-empty.")
    normalized_entry_path = "/" + trimmed_entry_path.strip("/")
    return "/" if normalized_entry_path == "/" else normalized_entry_path


def _workspace_path_depth(path_value: str) -> int:
    if path_value == "/":
        return 0
    return path_value.count("/")


def _ensure_metadata_dict(metadata_value: object) -> dict:
    if isinstance(metadata_value, dict):
        return metadata_value
    return {}


def _log_background_ingestion_failure(background_task: asyncio.Task) -> None:
    if background_task.cancelled():
        return
    exception = background_task.exception()
    if exception is not None:
        workspace_ingestion_logger.exception(
            "Unhandled ingestion task failure.",
            exc_info=exception,
        )
