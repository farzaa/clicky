from __future__ import annotations

import json
import os
import re
import traceback
from dataclasses import replace
from difflib import SequenceMatcher
from pathlib import Path
from tempfile import TemporaryDirectory

from .config import OcrProvider, ParseConfig
from .docling_backend import convert_with_docling
from .normalize import build_artifacts
from .ocr_fallback import (
    list_pdf_page_numbers,
    render_pages_from_source_pdf,
    run_page_ocr_with_provider,
    write_single_markdown_for_pdf,
)
from .topic_locator import locate_topic, normalize_topic, write_page_slice
from .utils import (
    build_parsed_output_directory_name,
    build_document_id,
    build_output_slug,
    build_topic_markdown_filename,
    compute_file_hash,
    ensure_directory,
    sanitize_filename_segment,
    slugify,
    utc_now_iso,
    write_json,
)
from .writer import write_artifacts


def parse_file(
    *,
    source_path: Path,
    output_root: Path,
    config: ParseConfig,
    logger,
) -> dict:
    source_path = source_path.resolve()
    output_root = output_root.resolve()

    if not source_path.exists():
        raise FileNotFoundError(f"Input PDF not found: {source_path}")
    if source_path.suffix.lower() != ".pdf":
        raise ValueError(f"Input is not a PDF: {source_path}")

    try:
        if config.single_markdown_only:
            result = write_single_markdown_for_pdf(
                source_path=source_path,
                output_root=output_root,
                config=config,
                logger=logger,
            )
            logger.info(
                "Parsed %s in single-markdown mode into %s",
                source_path.name,
                result["output_dir"],
            )
            return result

        file_hash = compute_file_hash(source_path)
        output_dir = output_root / build_output_slug(source_path.name, file_hash)
        ensure_directory(output_dir)

        conversion = convert_with_docling(source_path, config, logger)
        artifacts = build_artifacts(
            source_path=source_path,
            output_root=output_root,
            config=config,
            conversion_result=conversion.conversion_result,
            backend_used=conversion.backend_used,
            parse_warnings=conversion.warnings,
        )
        write_artifacts(
            artifacts,
            conversion.conversion_result.document,
            logger=logger,
            config=config,
        )

        logger.info(
            "Parsed %s with backend=%s into %s",
            source_path.name,
            conversion.backend_used,
            artifacts.output_dir,
        )
        return {
            "status": "success",
            "document_id": artifacts.document_id,
            "source": str(source_path),
            "output_dir": str(artifacts.output_dir),
            "backend_used": conversion.backend_used,
            "page_count": artifacts.metadata["processing"]["page_count"],
            "section_count": artifacts.metadata["processing"]["section_count"],
            "block_count": artifacts.metadata["processing"]["block_count"],
            "warnings": artifacts.metadata["processing"]["warnings"],
        }
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to parse %s", source_path)
        file_hash = compute_file_hash(source_path)
        output_dir = output_root / build_output_slug(source_path.name, file_hash)
        write_error_metadata(
            output_dir=output_dir,
            source_path=source_path,
            error=exc,
        )
        raise


def parse_folder(
    *,
    input_dir: Path,
    output_root: Path,
    config: ParseConfig,
    logger,
) -> dict:
    input_dir = input_dir.resolve()
    output_root = output_root.resolve()

    pattern = config.glob_pattern
    source_paths = (
        sorted(input_dir.rglob(pattern))
        if config.recursive
        else sorted(input_dir.glob(pattern))
    )

    results = []
    failed = 0

    for source_path in source_paths:
        try:
            results.append(
                parse_file(
                    source_path=source_path,
                    output_root=output_root,
                    config=config,
                    logger=logger,
                )
            )
        except Exception as exc:  # noqa: BLE001
            failed += 1
            results.append(
                {
                    "status": "error",
                    "source": str(source_path),
                    "error": str(exc),
                }
            )
            if not config.continue_on_error:
                break

    summary = {
        "status": "completed" if failed == 0 else "completed_with_errors",
        "input_dir": str(input_dir),
        "output_root": str(output_root),
        "processed_at": utc_now_iso(),
        "document_count": len(source_paths),
        "success_count": sum(result["status"] == "success" for result in results),
        "error_count": failed,
        "results": results,
    }
    ensure_directory(output_root)
    write_json(output_root / "run-summary.json", summary)
    return summary


def parse_topic(
    *,
    source_path: Path,
    topic: str,
    output_root: Path,
    config: ParseConfig,
    logger,
    context_pages: int,
    toc_scan_limit: int,
    validation_window: int,
    source_document_kind: str = "auto",
) -> dict:
    source_path = source_path.resolve()
    output_root = output_root.resolve()
    if not source_path.exists():
        raise FileNotFoundError(f"Input PDF not found: {source_path}")
    if source_path.suffix.lower() != ".pdf":
        raise ValueError(f"Input is not a PDF: {source_path}")

    normalized_source_document_kind = normalize_source_document_kind(source_document_kind)
    file_hash = compute_file_hash(source_path)
    output_dir = output_root / build_parsed_output_directory_name(source_path.name)
    ensure_directory(output_dir)
    topic_locator_path = output_dir / f"locator-{slugify(topic)}.json"
    existing_markdown_path, existing_page_markdowns = find_existing_topic_outputs(
        output_dir=output_dir,
        source_filename=source_path.name,
        topic=topic,
    )
    existing_metadata = read_json_if_exists(output_dir / "metadata.json")
    existing_locator = read_json_if_exists(topic_locator_path)
    existing_document_id = read_document_id(existing_metadata)
    existing_backend = read_processing_field(existing_metadata, "backend_used")
    existing_warnings_raw = read_processing_field(existing_metadata, "warnings")
    existing_warnings = existing_warnings_raw if isinstance(existing_warnings_raw, list) else []

    if (
        existing_markdown_path is not None
        and existing_markdown_path.exists()
        and existing_page_markdowns
    ):
        parsed_page_numbers = [item[0] for item in existing_page_markdowns]
        logger.info(
            "Topic cache hit for %s topic '%s' -> %s",
            source_path.name,
            topic,
            existing_markdown_path,
        )
        return build_topic_result(
            status="success_cached",
            topic=topic,
            output_dir=output_dir,
            document_id=existing_document_id or build_document_id(file_hash),
            topic_markdown_path=existing_markdown_path,
            topic_page_markdown_paths=existing_page_markdowns,
            locator=existing_locator,
            backend_used=existing_backend,
            warnings=existing_warnings,
            cache_hit=True,
            parsed_window=derive_parsed_window(
                locator=existing_locator,
                context_pages=context_pages,
                parsed_page_numbers=parsed_page_numbers,
            ),
        )

    parse_config = config
    if normalized_source_document_kind == "handwritten":
        if not os.getenv("MISTRAL_API_KEY"):
            raise RuntimeError(
                "Handwritten document mode requires MISTRAL_API_KEY for mistral-ocr parsing."
            )
        parse_config = replace(
            config,
            ocr_provider=OcrProvider.MISTRAL_OCR,
            enable_ocr=True,
        )

    locator: dict
    try:
        if normalized_source_document_kind == "handwritten":
            locator = locate_topic_with_ocr(
                source_path=source_path,
                topic=topic,
                provider=OcrProvider.MISTRAL_OCR.value,
                require_provider_match=True,
                logger=logger,
            )
        else:
            locator = locate_topic(
                source_path=source_path,
                topic=topic,
                toc_scan_limit=toc_scan_limit,
                validation_window=validation_window,
                source_document_kind=normalized_source_document_kind,
                logger=logger,
            )
    except Exception as locator_error:  # noqa: BLE001
        logger.warning(
            "Topic locator fallback to OCR for %s topic '%s': %s",
            source_path.name,
            topic,
            locator_error,
        )
        provider = (
            OcrProvider.MISTRAL_OCR.value
            if normalized_source_document_kind == "handwritten"
            else parse_config.ocr_provider.value
        )
        locator = locate_topic_with_ocr(
            source_path=source_path,
            topic=topic,
            provider=provider,
            require_provider_match=normalized_source_document_kind == "handwritten",
            logger=logger,
        )

    effective_context_pages = max(0, context_pages)
    target_index = locator["resolved_pdf_page_index"]
    if should_expand_topic_window(
        source_path=source_path,
        topic=topic,
        target_page_index=target_index,
        logger=logger,
    ):
        effective_context_pages = max(effective_context_pages, 1)

    start_index = max(0, target_index - effective_context_pages)
    end_index = min(locator["pdf_page_count"] - 1, target_index + effective_context_pages)
    page_indices = list(range(start_index, end_index + 1))
    page_labels = locator.get("page_labels", [])
    page_number_map = {
        local_page_no: pdf_page_index + 1
        for local_page_no, pdf_page_index in enumerate(page_indices, start=1)
    }
    page_label_map = {
        local_page_no: page_labels[pdf_page_index]
        if pdf_page_index < len(page_labels)
        else None
        for local_page_no, pdf_page_index in enumerate(page_indices, start=1)
    }

    with TemporaryDirectory(prefix="course-pdf-ingest-") as temp_dir:
        slice_path = Path(temp_dir) / "topic-slice.pdf"
        write_page_slice(
            source_path=source_path,
            output_path=slice_path,
            page_indices=page_indices,
        )
        conversion = convert_with_docling(slice_path, parse_config, logger)
        artifacts = build_artifacts(
            source_path=source_path,
            output_root=output_root,
            config=parse_config,
            conversion_result=conversion.conversion_result,
            backend_used=conversion.backend_used,
            parse_warnings=conversion.warnings,
            page_number_map=page_number_map,
            page_label_map=page_label_map,
        )
        artifacts.output_dir = output_dir
        write_artifacts(
            artifacts,
            conversion.conversion_result.document,
            logger=logger,
            config=parse_config,
        )
        write_json(topic_locator_path, locator)
        topic_markdown_path, topic_page_markdown_paths = write_topic_markdown_files(
            artifacts=artifacts,
            source_filename=source_path.name,
            topic=topic,
            locator=locator,
        )

    return build_topic_result(
        status="success",
        topic=topic,
        output_dir=artifacts.output_dir,
        document_id=artifacts.document_id,
        topic_markdown_path=topic_markdown_path,
        topic_page_markdown_paths=topic_page_markdown_paths,
        locator=locator,
        backend_used=artifacts.metadata["processing"]["backend_used"],
        warnings=artifacts.metadata["processing"]["warnings"],
        cache_hit=False,
        parsed_window=[start_index + 1, end_index + 1],
    )


def normalize_source_document_kind(source_document_kind: str) -> str:
    normalized_value = normalize_topic(source_document_kind)
    if normalized_value in {"with toc", "withtoc"}:
        return "with_toc"
    if normalized_value in {"without toc", "withouttoc", "no toc", "notoc"}:
        return "without_toc"
    if normalized_value in {"handwritten", "hand writing", "hand writing notes"}:
        return "handwritten"
    return "auto"


def find_existing_topic_outputs(
    *,
    output_dir: Path,
    source_filename: str,
    topic: str,
) -> tuple[Path | None, list[tuple[int, Path]]]:
    requested_markdown_path = output_dir / build_topic_markdown_filename(
        source_filename=source_filename,
        topic=topic,
        page_number=None,
    )
    if not requested_markdown_path.exists():
        return None, []

    source_stem = sanitize_filename_segment(Path(source_filename).stem, max_length=90) or "document"
    clean_topic = sanitize_filename_segment(topic, max_length=120) or "topic"
    filename_pattern = re.compile(
        rf"^{re.escape(source_stem)} {re.escape(clean_topic)} markdown page (\d+)\.md$",
        re.IGNORECASE,
    )
    page_markdown_paths: list[tuple[int, Path]] = []
    for candidate in sorted(output_dir.glob("*.md")):
        match = filename_pattern.match(candidate.name)
        if not match:
            continue
        page_markdown_paths.append((int(match.group(1)), candidate))
    page_markdown_paths.sort(key=lambda item: item[0])
    return requested_markdown_path, page_markdown_paths


def write_topic_markdown_files(
    *,
    artifacts,
    source_filename: str,
    topic: str,
    locator: dict,
) -> tuple[Path, list[tuple[int, Path]]]:
    resolved_page_number = int(locator.get("resolved_pdf_page_number") or 0)
    parsed_page_numbers = sorted(artifacts.page_markdown)
    if not parsed_page_numbers and resolved_page_number > 0:
        parsed_page_numbers = [resolved_page_number]

    topic_page_markdown_paths: list[tuple[int, Path]] = []
    for page_number in parsed_page_numbers:
        output_path = artifacts.output_dir / build_topic_markdown_filename(
            source_filename=source_filename,
            topic=topic,
            page_number=page_number,
        )
        page_markdown = artifacts.page_markdown.get(page_number, "")
        page_lines = [
            f"# {topic} markdown page {page_number}",
            "",
            "## Topic Metadata",
            "",
            f"- topic_query: `{topic}`",
            f"- matched_title: `{locator.get('matched_candidate', {}).get('title', topic)}`",
            f"- resolved_pdf_page_number: `{locator.get('resolved_pdf_page_number')}`",
            f"- current_pdf_page_number: `{page_number}`",
            f"- resolved_book_page_label: `{locator.get('resolved_book_page_label')}`",
            f"- match_source: `{locator.get('matched_candidate', {}).get('source', '')}`",
            f"- output_dir: `{artifacts.output_dir}`",
            "",
            "## Parsed Page Content",
            "",
            page_markdown or "_No page markdown generated._",
        ]
        output_path.write_text("\n".join(page_lines).strip() + "\n", encoding="utf-8")
        topic_page_markdown_paths.append((page_number, output_path))

    topic_summary_path = artifacts.output_dir / build_topic_markdown_filename(
        source_filename=source_filename,
        topic=topic,
        page_number=None,
    )
    summary_lines = [
        f"# {topic} markdown",
        "",
        "## Topic Metadata",
        "",
        f"- topic_query: `{topic}`",
        f"- matched_title: `{locator.get('matched_candidate', {}).get('title', topic)}`",
        f"- resolved_pdf_page_number: `{locator.get('resolved_pdf_page_number')}`",
        f"- resolved_book_page_label: `{locator.get('resolved_book_page_label')}`",
        f"- parsed_pdf_page_numbers: `{parsed_page_numbers}`",
        f"- match_source: `{locator.get('matched_candidate', {}).get('source', '')}`",
        f"- output_dir: `{artifacts.output_dir}`",
        "",
        "## Topic Page Markdown Files",
        "",
    ]
    if topic_page_markdown_paths:
        for page_number, page_markdown_path in topic_page_markdown_paths:
            summary_lines.append(f"- page {page_number}: `{page_markdown_path.name}`")
    else:
        summary_lines.append("_No topic pages were generated._")

    summary_lines.extend(["", "## Parsed Topic Content", ""])
    if topic_page_markdown_paths:
        for page_number, _page_markdown_path in topic_page_markdown_paths:
            summary_lines.extend([f"### Page {page_number}", ""])
            summary_lines.append(
                artifacts.page_markdown.get(page_number, "_No page markdown generated._")
            )
            summary_lines.append("")
    else:
        summary_lines.append("_No parsed page content generated._")

    topic_summary_path.write_text("\n".join(summary_lines).strip() + "\n", encoding="utf-8")
    return topic_summary_path, topic_page_markdown_paths


def read_json_if_exists(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def read_document_id(metadata: dict | None) -> str | None:
    if not metadata:
        return None
    value = metadata.get("document_id")
    return str(value) if value else None


def read_processing_field(metadata: dict | None, field: str):
    if not metadata:
        return None
    processing = metadata.get("processing")
    if not isinstance(processing, dict):
        return None
    return processing.get(field)


def derive_parsed_window(
    *,
    locator: dict | None,
    context_pages: int,
    parsed_page_numbers: list[int] | None,
) -> list[int] | None:
    if parsed_page_numbers:
        return [min(parsed_page_numbers), max(parsed_page_numbers)]
    if not locator:
        return None
    resolved_index = locator.get("resolved_pdf_page_index")
    pdf_page_count = locator.get("pdf_page_count")
    if not isinstance(resolved_index, int) or not isinstance(pdf_page_count, int):
        return None
    start = max(0, resolved_index - context_pages)
    end = min(pdf_page_count - 1, resolved_index + context_pages)
    return [start + 1, end + 1]


def build_topic_result(
    *,
    status: str,
    topic: str,
    output_dir: Path,
    document_id: str,
    topic_markdown_path: Path,
    topic_page_markdown_paths: list[tuple[int, Path]],
    locator: dict | None,
    backend_used: str | None,
    warnings: list[str],
    cache_hit: bool,
    parsed_window: list[int] | None,
) -> dict:
    payload = {
        "status": status,
        "cache_hit": cache_hit,
        "topic": topic,
        "output_dir": str(output_dir),
        "document_id": document_id,
        "topic_markdown_path": str(topic_markdown_path),
        "topic_page_markdown_paths": [
            {
                "page_number": page_number,
                "path": str(path),
            }
            for page_number, path in topic_page_markdown_paths
        ],
        "backend_used": backend_used,
        "warnings": warnings,
    }
    if locator:
        payload.update(
            {
                "matched_title": locator["matched_candidate"]["title"],
                "resolved_pdf_page_number": locator["resolved_pdf_page_number"],
                "resolved_book_page_label": locator["resolved_book_page_label"],
            }
        )
    if parsed_window is not None:
        payload["parsed_pdf_page_window"] = parsed_window
    return payload


def locate_topic_with_ocr(
    *,
    source_path: Path,
    topic: str,
    provider: str,
    require_provider_match: bool,
    logger,
) -> dict:
    page_numbers = list_pdf_page_numbers(source_path=source_path)
    if not page_numbers:
        raise RuntimeError("Unable to enumerate PDF pages for OCR topic detection.")

    with TemporaryDirectory(prefix="course-pdf-ingest-topic-ocr-") as temp_dir:
        image_dir = Path(temp_dir)
        page_image_map = render_pages_from_source_pdf(
            source_path=source_path,
            page_numbers=page_numbers,
            asset_dir=image_dir,
            logger=logger,
            scale=4.2,
        )
        page_results, engines_used, provider_used = run_page_ocr_with_provider(
            provider=provider,
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            source_path=source_path,
            logger=logger,
        )

    if not page_results:
        raise RuntimeError("OCR topic detection did not return text for any page.")
    if require_provider_match and provider_used != provider:
        raise RuntimeError(
            f"OCR provider fallback is not allowed in handwritten mode. "
            f"requested='{provider}' resolved='{provider_used}'."
        )

    best_page_number, best_score = choose_best_ocr_page(topic=topic, page_results=page_results)
    if best_page_number < 1:
        raise RuntimeError("OCR topic detection could not resolve a target page.")

    best_page_lines = page_results[best_page_number].lines
    matched_title = best_page_lines[0][:120] if best_page_lines else topic
    return {
        "topic_query": topic,
        "matched_candidate": {
            "source": f"ocr_{provider_used}",
            "title": matched_title or topic,
            "pdf_page_index": best_page_number - 1,
            "printed_page_label": str(best_page_number),
            "toc_page_index": None,
            "path": [matched_title or topic],
            "score": round(best_score, 4),
        },
        "pdf_page_count": len(page_numbers),
        "page_labels_available": False,
        "page_labels": [],
        "page_labels_sample": [],
        "offset_hint": None,
        "resolved_pdf_page_index": best_page_number - 1,
        "resolved_pdf_page_number": best_page_number,
        "resolved_book_page_label": str(best_page_number),
        "outline_candidate_count": 0,
        "toc_candidate_count": 0,
        "header_candidate_count": 0,
        "toc_candidates_preview": [],
        "header_candidates_preview": [],
        "ocr_provider_used": provider_used,
        "ocr_engines_used": engines_used,
    }


def choose_best_ocr_page(*, topic: str, page_results: dict[int, object]) -> tuple[int, float]:
    best_page_number = 0
    best_score = -1.0
    for page_number, page_result in page_results.items():
        lines = getattr(page_result, "lines", None) or []
        page_text = " ".join(lines)
        score = calculate_topic_match_score(topic=topic, candidate_text=page_text)
        if score > best_score:
            best_page_number = page_number
            best_score = score
    return best_page_number, best_score


def calculate_topic_match_score(*, topic: str, candidate_text: str) -> float:
    topic_normalized = normalize_topic(topic)
    candidate_normalized = normalize_topic(candidate_text[:10000])
    if not candidate_normalized:
        return 0.0

    ratio = SequenceMatcher(None, topic_normalized, candidate_normalized).ratio()
    topic_tokens = set(topic_normalized.split())
    candidate_tokens = set(candidate_normalized.split())
    overlap = (
        len(topic_tokens & candidate_tokens) / max(len(topic_tokens), 1)
        if topic_tokens
        else 0.0
    )
    return ratio * 0.55 + overlap * 0.45


def should_expand_topic_window(
    *,
    source_path: Path,
    topic: str,
    target_page_index: int,
    logger,
) -> bool:
    page_text = read_text_from_pdf_page(
        source_path=source_path,
        page_index=target_page_index,
        logger=logger,
    )
    if not page_text:
        return True

    topic_normalized = normalize_topic(topic)
    page_normalized = normalize_topic(page_text[:10000])
    if not topic_normalized or not page_normalized:
        return True

    ratio = SequenceMatcher(None, topic_normalized, page_normalized).ratio()
    topic_tokens = set(topic_normalized.split())
    page_tokens = set(page_normalized.split())
    overlap = (
        len(topic_tokens & page_tokens) / max(len(topic_tokens), 1)
        if topic_tokens
        else 0.0
    )
    return overlap < 0.45 and ratio < 0.22


def read_text_from_pdf_page(
    *,
    source_path: Path,
    page_index: int,
    logger,
) -> str:
    try:
        from pypdf import PdfReader

        reader = PdfReader(str(source_path))
        if page_index < 0 or page_index >= len(reader.pages):
            return ""
        page = reader.pages[page_index]
        return page.extract_text(extraction_mode="layout") or page.extract_text() or ""
    except Exception as exc:  # noqa: BLE001
        logger.warning("Failed to read PDF text for topic coverage check: %s", exc)
        return ""


def write_error_metadata(*, output_dir: Path, source_path: Path, error: Exception) -> None:
    ensure_directory(output_dir)
    file_hash = compute_file_hash(source_path)
    document_id = build_document_id(file_hash)
    payload = {
        "schema_version": "1.0",
        "document_id": document_id,
        "source": {
            "filename": source_path.name,
            "absolute_path": str(source_path),
            "sha256": file_hash,
        },
        "processing": {
            "status": "error",
            "parsed_at": utc_now_iso(),
            "error_type": type(error).__name__,
            "error_message": str(error),
            "traceback": traceback.format_exc(),
        },
    }
    write_json(output_dir / "metadata.json", payload)
