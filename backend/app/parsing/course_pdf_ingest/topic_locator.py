from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from pypdf import PdfReader, PdfWriter
from pypdf.generic import Destination


TOC_LINE_PATTERN = re.compile(
    r"^(?P<title>.+?)(?:\s*\.{2,}\s*|\s{2,})(?P<label>[A-Za-z0-9ivxlcdmIVXLCDM-]+)\s*$"
)
ROMAN_PATTERN = re.compile(r"^[ivxlcdm]+$", re.IGNORECASE)


@dataclass(slots=True)
class TopicCandidate:
    source: str
    title: str
    pdf_page_index: int | None
    printed_page_label: str | None
    toc_page_index: int | None
    path: list[str]
    score: float = 0.0


def locate_topic(
    *,
    source_path: Path,
    topic: str,
    toc_scan_limit: int,
    validation_window: int,
    source_document_kind: str = "auto",
    logger,
) -> dict[str, Any]:
    reader = PdfReader(str(source_path))
    page_labels = list(getattr(reader, "page_labels", []) or [])

    outline_candidates = extract_outline_candidates(reader, page_labels)
    toc_candidates = extract_printed_toc_candidates(reader, page_labels, toc_scan_limit)
    header_candidates = extract_header_candidates(reader, page_labels)
    offset_hint = infer_visible_page_offset(reader)

    for candidate in toc_candidates:
        if candidate.pdf_page_index is None and candidate.printed_page_label:
            candidate.pdf_page_index = map_label_to_pdf_index(
                candidate.printed_page_label,
                page_labels,
                offset_hint,
            )

    all_candidates = choose_candidates_for_document_kind(
        source_document_kind=source_document_kind,
        outline_candidates=outline_candidates,
        toc_candidates=toc_candidates,
        header_candidates=header_candidates,
    )
    if not all_candidates:
        raise RuntimeError(
            "No outline, printed table-of-contents, or page-header candidates were detected."
        )

    match = choose_best_candidate(topic, all_candidates)
    if match.pdf_page_index is None:
        raise RuntimeError("Found a matching TOC topic, but could not map it to a PDF page.")

    validated_index = validate_target_page(
        reader=reader,
        estimated_page_index=match.pdf_page_index,
        title=match.title,
        validation_window=validation_window,
    )
    pdf_page_count = len(reader.pages)
    validated_index = max(0, min(pdf_page_count - 1, validated_index))

    return {
        "topic_query": topic,
        "matched_candidate": asdict(match),
        "pdf_page_count": pdf_page_count,
        "page_labels_available": bool(page_labels),
        "page_labels": page_labels,
        "page_labels_sample": page_labels[: min(20, len(page_labels))],
        "offset_hint": offset_hint,
        "resolved_pdf_page_index": validated_index,
        "resolved_pdf_page_number": validated_index + 1,
        "resolved_book_page_label": page_labels[validated_index] if page_labels else None,
        "outline_candidate_count": len(outline_candidates),
        "toc_candidate_count": len(toc_candidates),
        "header_candidate_count": len(header_candidates),
        "toc_candidates_preview": [asdict(item) for item in toc_candidates[:20]],
        "header_candidates_preview": [asdict(item) for item in header_candidates[:20]],
        "source_document_kind": source_document_kind,
    }


def choose_candidates_for_document_kind(
    *,
    source_document_kind: str,
    outline_candidates: list[TopicCandidate],
    toc_candidates: list[TopicCandidate],
    header_candidates: list[TopicCandidate],
) -> list[TopicCandidate]:
    normalized_kind = normalize_topic(source_document_kind)
    if normalized_kind in {"with toc", "withtoc"}:
        return outline_candidates + toc_candidates or header_candidates
    if normalized_kind in {"without toc", "withouttoc", "no toc", "notoc"}:
        return header_candidates or outline_candidates + toc_candidates
    return outline_candidates + toc_candidates or header_candidates


def extract_outline_candidates(reader: PdfReader, page_labels: list[str]) -> list[TopicCandidate]:
    outline = getattr(reader, "outline", None) or []
    result: list[TopicCandidate] = []

    def walk(items: list[Any], path: list[str]) -> None:
        for item in items:
            if isinstance(item, list):
                walk(item, path)
                continue
            if isinstance(item, Destination):
                title = str(item.title).strip()
                page_index = reader.get_destination_page_number(item)
                result.append(
                    TopicCandidate(
                        source="outline",
                        title=title,
                        pdf_page_index=page_index,
                        printed_page_label=page_labels[page_index] if page_labels else None,
                        toc_page_index=None,
                        path=[*path, title],
                    )
                )
                children = getattr(item, "children", None)
                if isinstance(children, list):
                    walk(children, [*path, title])

    if isinstance(outline, list):
        walk(outline, [])

    return dedupe_candidates(result)


def extract_printed_toc_candidates(
    reader: PdfReader,
    page_labels: list[str],
    toc_scan_limit: int,
) -> list[TopicCandidate]:
    result: list[TopicCandidate] = []
    page_count = min(len(reader.pages), toc_scan_limit)

    for toc_page_index in range(page_count):
        page = reader.pages[toc_page_index]
        text = page.extract_text(extraction_mode="layout") or page.extract_text() or ""
        lines = [normalize_spaces(line) for line in text.splitlines() if normalize_spaces(line)]
        has_contents_heading = any(re.fullmatch(r"(table of )?contents", line, re.IGNORECASE) for line in lines)

        page_matches = []
        for line in lines:
            match = TOC_LINE_PATTERN.match(line)
            if not match:
                continue
            title = clean_toc_title(match.group("title"))
            page_label = match.group("label")
            page_matches.append(
                TopicCandidate(
                    source="printed_toc",
                    title=title,
                    pdf_page_index=map_label_to_pdf_index(page_label, page_labels, None),
                    printed_page_label=page_label,
                    toc_page_index=toc_page_index,
                    path=[title],
                )
            )

        if has_contents_heading or len(page_matches) >= 3:
            result.extend(page_matches)

    return dedupe_candidates(result)


def extract_header_candidates(reader: PdfReader, page_labels: list[str]) -> list[TopicCandidate]:
    page_top_lines: list[list[str]] = []
    recurring_counter: dict[str, int] = {}

    for page_index in range(len(reader.pages)):
        text = reader.pages[page_index].extract_text(extraction_mode="layout") or reader.pages[
            page_index
        ].extract_text() or ""
        lines = [normalize_spaces(line) for line in text.splitlines() if normalize_spaces(line)]
        top_lines = lines[:10]
        page_top_lines.append(top_lines)
        for line in top_lines[:5]:
            key = normalize_topic(line)
            if key:
                recurring_counter[key] = recurring_counter.get(key, 0) + 1

    recurring = {
        key
        for key, count in recurring_counter.items()
        if count >= max(3, len(reader.pages) // 5)
    }

    candidates: list[TopicCandidate] = []
    previous_title = ""
    for page_index, top_lines in enumerate(page_top_lines):
        title = choose_page_header(top_lines, recurring)
        if not title:
            continue
        title_norm = normalize_topic(title)
        if title_norm == previous_title:
            continue
        previous_title = title_norm
        candidates.append(
            TopicCandidate(
                source="page_header",
                title=title,
                pdf_page_index=page_index,
                printed_page_label=page_labels[page_index] if page_labels else None,
                toc_page_index=None,
                path=[title],
            )
        )

    return dedupe_candidates(candidates)


def choose_best_candidate(topic: str, candidates: list[TopicCandidate]) -> TopicCandidate:
    scored = []
    query_norm = normalize_topic(topic)

    for candidate in candidates:
        title_norm = normalize_topic(candidate.title)
        if not title_norm:
            continue
        ratio = SequenceMatcher(None, query_norm, title_norm).ratio()
        query_tokens = set(tokenize(query_norm))
        title_tokens = set(tokenize(title_norm))
        overlap = (
            len(query_tokens & title_tokens) / max(len(query_tokens), 1)
            if query_tokens
            else 0.0
        )
        exact_bonus = 0.2 if query_norm == title_norm else 0.0
        source_bonus = 0.1 if candidate.source == "outline" else 0.03 if candidate.source == "printed_toc" else 0.0
        candidate.score = round(ratio * 0.7 + overlap * 0.3 + exact_bonus + source_bonus, 4)
        scored.append(candidate)

    if not scored:
        raise RuntimeError("No TOC candidates were available for topic matching.")

    scored.sort(key=lambda item: item.score, reverse=True)
    return scored[0]


def validate_target_page(
    *,
    reader: PdfReader,
    estimated_page_index: int,
    title: str,
    validation_window: int,
) -> int:
    title_norm = normalize_topic(title)
    title_tokens = set(tokenize(title_norm))
    best_index = estimated_page_index
    best_score = -1.0

    for page_index in range(
        max(0, estimated_page_index - validation_window),
        min(len(reader.pages), estimated_page_index + validation_window + 1),
    ):
        text = reader.pages[page_index].extract_text(extraction_mode="layout") or ""
        snippet = normalize_topic(text[:4000])
        ratio = SequenceMatcher(None, title_norm, snippet).ratio()
        snippet_tokens = set(tokenize(snippet))
        overlap = len(title_tokens & snippet_tokens) / max(len(title_tokens), 1) if title_tokens else 0.0
        proximity_bonus = max(0.0, 0.15 - abs(page_index - estimated_page_index) * 0.02)
        score = ratio * 0.5 + overlap * 0.35 + proximity_bonus
        if score > best_score:
            best_score = score
            best_index = page_index

    return best_index


def map_label_to_pdf_index(
    label: str,
    page_labels: list[str],
    offset_hint: int | None,
) -> int | None:
    normalized_label = normalize_page_label(label)
    if page_labels:
        normalized_labels = [normalize_page_label(item) for item in page_labels]
        if normalized_label in normalized_labels:
            return normalized_labels.index(normalized_label)

    if offset_hint is not None and normalized_label and normalized_label.isdigit():
        return max(0, int(normalized_label) + offset_hint - 1)

    return None


def infer_visible_page_offset(reader: PdfReader, max_scan_pages: int = 40) -> int | None:
    candidates: list[int] = []

    for page_index in range(min(len(reader.pages), max_scan_pages)):
        text = reader.pages[page_index].extract_text(extraction_mode="layout") or ""
        lines = [normalize_spaces(line) for line in text.splitlines() if normalize_spaces(line)]
        edge_lines = lines[:3] + lines[-3:]

        for line in edge_lines:
            normalized = normalize_page_label(line)
            if normalized.isdigit():
                printed = int(normalized)
                candidates.append((page_index + 1) - printed)

    if not candidates:
        return None

    counts: dict[int, int] = {}
    for offset in candidates:
        counts[offset] = counts.get(offset, 0) + 1

    return sorted(counts.items(), key=lambda item: item[1], reverse=True)[0][0]


def write_page_slice(
    *,
    source_path: Path,
    output_path: Path,
    page_indices: list[int],
) -> None:
    reader = PdfReader(str(source_path))
    writer = PdfWriter()
    for page_index in page_indices:
        writer.add_page(reader.pages[page_index])
    with output_path.open("wb") as handle:
        writer.write(handle)


def dedupe_candidates(candidates: list[TopicCandidate]) -> list[TopicCandidate]:
    seen = set()
    deduped = []
    for candidate in candidates:
        key = (normalize_topic(candidate.title), candidate.pdf_page_index, candidate.printed_page_label)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(candidate)
    return deduped


def choose_page_header(top_lines: list[str], recurring: set[str]) -> str | None:
    filtered = []
    for line in top_lines:
        norm = normalize_topic(line)
        if not norm:
            continue
        if norm in recurring:
            continue
        if is_page_number_only(line):
            continue
        if len(norm) < 4:
            continue
        filtered.append(line)

    if not filtered:
        return None

    title_like = [line for line in filtered if looks_like_header(line)]
    if title_like:
        return title_like[0]

    return filtered[0]


def looks_like_header(value: str) -> bool:
    stripped = normalize_spaces(value)
    if len(stripped) > 140:
        return False
    if stripped.lower() == "content":
        return False
    alpha = sum(character.isalpha() for character in stripped)
    if alpha < 3:
        return False
    words = stripped.split()
    if len(words) > 14:
        return False
    if stripped.isupper() and len(words) <= 3:
        return False
    return True


def is_page_number_only(value: str) -> bool:
    normalized = normalize_spaces(value)
    if normalized.isdigit():
        return True
    return bool(ROMAN_PATTERN.fullmatch(normalized))


def clean_toc_title(value: str) -> str:
    return normalize_spaces(re.sub(r"[.\s]+$", "", value))


def normalize_topic(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def tokenize(value: str) -> list[str]:
    return [token for token in value.split() if token]


def normalize_spaces(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def normalize_page_label(value: str) -> str:
    label = normalize_spaces(value)
    if ROMAN_PATTERN.fullmatch(label):
        return str(roman_to_int(label))
    return label


def roman_to_int(value: str) -> int:
    symbols = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
    total = 0
    previous = 0
    for char in reversed(value.upper()):
        current = symbols.get(char, 0)
        total += -current if current < previous else current
        previous = current
    return total
