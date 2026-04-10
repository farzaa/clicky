from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import re
from typing import Any

from docling_core.types.doc import ImageRefMode

from .config import ParseConfig
from .models import ParsedArtifacts
from .utils import build_document_id, build_output_slug, compute_file_hash, safe_text, utc_now_iso

SCHEMA_VERSION = "1.0"
MARKDOWN_IMAGE_PATTERN = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")


def build_artifacts(
    *,
    source_path: Path,
    output_root: Path,
    config: ParseConfig,
    conversion_result: Any,
    backend_used: str,
    parse_warnings: list[str],
    page_number_map: dict[int, int] | None = None,
    page_label_map: dict[int, str] | None = None,
    output_suffix: str | None = None,
) -> ParsedArtifacts:
    document = conversion_result.document
    file_hash = compute_file_hash(source_path)
    document_id = build_document_id(file_hash)
    base_slug = build_output_slug(source_path.name, file_hash)
    output_dir = output_root / (f"{base_slug}-{output_suffix}" if output_suffix else base_slug)

    raw_document = export_document_dict(document)
    markdown = document.export_to_markdown(
        image_mode=ImageRefMode.REFERENCED,
        traverse_pictures=True,
    )

    blocks, sections, page_sections = build_blocks(
        document=document,
        raw_document=raw_document,
        document_id=document_id,
        source_path=source_path,
        page_number_map=page_number_map,
        page_label_map=page_label_map,
    )
    pages = build_pages(
        document=document,
        raw_document=raw_document,
        document_id=document_id,
        source_path=source_path,
        blocks=blocks,
        page_sections=page_sections,
        page_number_map=page_number_map,
        page_label_map=page_label_map,
    )

    finalize_sections(sections, blocks)
    toc = build_toc(sections)
    page_markdown = build_page_markdown(
        document=document,
        pages=pages,
        blocks=blocks,
    )
    section_markdown = build_section_markdown(sections, blocks)

    title = infer_document_title(raw_document, blocks, source_path)
    content_type_counts = Counter(block["content_type"] for block in blocks)
    warnings = list(parse_warnings)

    metadata = {
        "schema_version": SCHEMA_VERSION,
        "document_id": document_id,
        "document_title": title,
        "source": {
            "filename": source_path.name,
            "absolute_path": str(source_path),
            "extension": source_path.suffix.lower(),
            "size_bytes": source_path.stat().st_size,
            "sha256": file_hash,
        },
        "processing": {
            "parser": "docling",
            "profile": config.profile.value,
            "backend_requested": config.backend.value,
            "backend_used": backend_used,
            "status": str(conversion_result.status),
            "warnings": warnings,
            "parsed_at": utc_now_iso(),
            "page_count": len(pages),
            "section_count": len(sections),
            "block_count": len(blocks),
            "content_type_counts": dict(content_type_counts),
        },
    }

    normalized_document = {
        "schema_version": SCHEMA_VERSION,
        "document": {
            "document_id": document_id,
            "title": title,
            "source_filename": source_path.name,
            "source_path": str(source_path),
            "page_count": len(pages),
            "file_hash_sha256": file_hash,
        },
        "processing": metadata["processing"],
        "toc": toc,
        "pages": pages,
        "sections": sections,
        "blocks": blocks,
    }

    return ParsedArtifacts(
        document_id=document_id,
        source_path=source_path,
        output_dir=output_dir,
        raw_document=raw_document,
        normalized_document=normalized_document,
        metadata=metadata,
        markdown=markdown,
        page_markdown=page_markdown,
        section_markdown=section_markdown,
    )


def export_document_dict(document: Any) -> dict[str, Any]:
    if hasattr(document, "export_to_dict"):
        return document.export_to_dict()
    if hasattr(document, "model_dump"):
        return document.model_dump(mode="json")
    raise RuntimeError("Unable to serialize Docling document to a dictionary.")


def build_blocks(
    *,
    document: Any,
    raw_document: dict[str, Any],
    document_id: str,
    source_path: Path,
    page_number_map: dict[int, int] | None = None,
    page_label_map: dict[int, str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[int, dict[str, Any]]]:
    blocks: list[dict[str, Any]] = []
    sections: list[dict[str, Any]] = []
    page_section_cache: dict[int, dict[str, Any]] = {}
    section_stack: list[dict[str, Any]] = []
    page_order_map: Counter[int] = Counter()
    section_block_order: Counter[str] = Counter()
    section_count = 0

    for global_order, (item, level) in enumerate(document.iterate_items(), start=1):
        label = safe_text(getattr(item, "label", "unknown")) or "unknown"
        item_type = type(item).__name__
        self_ref = safe_text(getattr(item, "self_ref", ""))
        raw_entry = lookup_ref(raw_document, self_ref)
        provenances = extract_provenance(item)
        page_numbers = sorted(
            {prov["page_number"] for prov in provenances if prov.get("page_number") is not None}
        )
        docling_page_number = page_numbers[0] if page_numbers else None
        page_number = (
            page_number_map.get(docling_page_number, docling_page_number)
            if page_number_map
            else docling_page_number
        )
        page_label = (
            page_label_map.get(docling_page_number)
            if page_label_map and docling_page_number is not None
            else None
        )
        page_order_key = page_number if page_number is not None else 0
        content_type = classify_content_type(label, item_type)
        text = extract_item_text(item, raw_entry)

        if not text and content_type not in {"table", "figure", "formula"}:
            continue

        if is_heading_type(content_type):
            while section_stack and section_stack[-1]["heading_level"] >= level:
                section_stack.pop()

            section_count += 1
            path = [*section_stack[-1]["heading_path"], text] if section_stack else [text]
            section_id = f"{document_id}:section:{section_count:04d}"
            section = {
                "section_id": section_id,
                "document_id": document_id,
                "title": text,
                "heading_level": level,
                "heading_path": path,
                "slug_path": [simple_slug(part) for part in path],
                "source_filename": source_path.name,
                "page_start": page_number,
                "page_end": page_number,
                "block_ids": [],
                "text": "",
                "is_synthetic": False,
                "order": section_count,
            }
            sections.append(section)
            section_stack.append(section)
            current_section = section
        else:
            current_section = section_stack[-1] if section_stack else get_or_create_page_section(
                cache=page_section_cache,
                sections=sections,
                document_id=document_id,
                source_filename=source_path.name,
                page_number=page_number,
            )

        block_id = f"{document_id}:block:{global_order:06d}"
        page_order_map[page_order_key] += 1
        section_block_order[current_section["section_id"]] += 1

        block = {
            "block_id": block_id,
            "document_id": document_id,
            "source_filename": source_path.name,
            "page_number": page_number,
            "docling_page_number": docling_page_number,
            "book_page_label": page_label,
            "page_numbers": page_numbers,
            "section_id": current_section["section_id"],
            "section_heading_path": current_section["heading_path"],
            "content_type": content_type,
            "text": text,
            "global_order": global_order,
            "page_block_order": page_order_map[page_order_key],
            "section_block_order": section_block_order[current_section["section_id"]],
            "heading_level": level if is_heading_type(content_type) else None,
            "layout": {
                "docling_item_type": item_type,
                "docling_label": label,
                "self_ref": self_ref,
                "parent_ref": safe_text(getattr(item, "parent", "")),
                "children_refs": [safe_text(child) for child in (getattr(item, "children", []) or [])],
                "provenance": provenances,
            },
            "media_refs": extract_media_refs(raw_entry),
            "captions": extract_ref_texts(raw_document, raw_entry.get("captions") if isinstance(raw_entry, dict) else None),
            "references": extract_ref_texts(raw_document, raw_entry.get("references") if isinstance(raw_entry, dict) else None),
            "raw_entry_ref": self_ref,
        }

        blocks.append(block)
        current_section["block_ids"].append(block_id)
        current_section["page_end"] = page_number or current_section["page_end"]
        if text:
            current_section["text"] = join_text(current_section["text"], text)

    return blocks, sections, page_section_cache


def build_pages(
    *,
    document: Any,
    raw_document: dict[str, Any],
    document_id: str,
    source_path: Path,
    blocks: list[dict[str, Any]],
    page_sections: dict[int, dict[str, Any]],
    page_number_map: dict[int, int] | None = None,
    page_label_map: dict[int, str] | None = None,
) -> list[dict[str, Any]]:
    page_specs = raw_document.get("pages", {})
    pages: list[dict[str, Any]] = []

    blocks_by_page: dict[int, list[dict[str, Any]]] = {}
    for block in blocks:
        blocks_by_page.setdefault(block["page_number"], []).append(block)

    for page_key, page_payload in sorted(page_specs.items(), key=lambda item: int(item[0])):
        docling_page_number = int(page_key)
        page_number = (
            page_number_map.get(docling_page_number, docling_page_number)
            if page_number_map
            else docling_page_number
        )
        page_blocks = blocks_by_page.get(page_number, [])
        section_ids = unique_preserving_order(block["section_id"] for block in page_blocks)
        page_text = "\n\n".join(block["text"] for block in page_blocks if block["text"])
        content_type_counts = dict(Counter(block["content_type"] for block in page_blocks))

        pages.append(
            {
                "document_id": document_id,
                "source_filename": source_path.name,
                "page_number": page_number,
                "docling_page_number": docling_page_number,
                "page_index": page_number - 1 if page_number is not None else None,
                "book_page_label": (
                    page_label_map.get(docling_page_number)
                    if page_label_map
                    else None
                ),
                "size": page_payload.get("size"),
                "section_ids": section_ids,
                "block_ids": [block["block_id"] for block in page_blocks],
                "text": page_text,
                "content_type_counts": content_type_counts,
                "figure_block_ids": [block["block_id"] for block in page_blocks if block["content_type"] == "figure"],
                "markdown_path": f"pages/page-{page_number:04d}.md",
                "synthetic_section_id": page_sections.get(page_number, {}).get("section_id"),
            }
        )

    return pages


def finalize_sections(sections: list[dict[str, Any]], blocks: list[dict[str, Any]]) -> None:
    block_lookup = {block["block_id"]: block for block in blocks}
    for section in sections:
        section_blocks = [block_lookup[block_id] for block_id in section["block_ids"]]
        section["page_numbers"] = unique_preserving_order(
            block["page_number"] for block in section_blocks if block["page_number"] is not None
        )
        section["page_span"] = [section["page_start"], section["page_end"]]
        section["block_count"] = len(section_blocks)
        section["content_types"] = dict(Counter(block["content_type"] for block in section_blocks))


def build_toc(sections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    toc_sections = [section for section in sections if not section.get("is_synthetic")]
    if not toc_sections:
        toc_sections = sections

    nodes: list[dict[str, Any]] = []
    stack: list[dict[str, Any]] = []

    for section in toc_sections:
        node = {
            "section_id": section["section_id"],
            "title": section["title"],
            "heading_level": section["heading_level"],
            "heading_path": section["heading_path"],
            "page_start": section["page_start"],
            "page_end": section["page_end"],
            "children": [],
        }

        while stack and stack[-1]["heading_level"] >= section["heading_level"]:
            stack.pop()

        if stack:
            stack[-1]["children"].append(node)
        else:
            nodes.append(node)

        stack.append(node)

    return nodes


def build_page_markdown(
    *,
    document: Any,
    pages: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
) -> dict[int, str]:
    blocks_by_page: dict[int, list[dict[str, Any]]] = {}
    for block in blocks:
        blocks_by_page.setdefault(block["page_number"], []).append(block)

    rendered: dict[int, str] = {}
    for page in pages:
        page_number = page["page_number"]
        page_blocks = sorted(
            blocks_by_page.get(page_number, []),
            key=lambda block: (block["page_block_order"], block["global_order"]),
        )
        section_path = " > ".join(page_blocks[0]["section_heading_path"]) if page_blocks else ""

        lines = [f"# Page {page_number}", ""]
        lines.extend(
            [
                "## Metadata",
                "",
                f"- document_id: `{page['document_id']}`",
                f"- source_file: `{page['source_filename']}`",
                f"- pdf_page_number: `{page['page_number']}`",
                f"- book_page_label: `{page.get('book_page_label') or ''}`",
                f"- docling_page_number: `{page['docling_page_number']}`",
                f"- page_index_zero_based: `{page.get('page_index')}`",
                f"- section_path: `{section_path}`",
                f"- block_count: `{len(page_blocks)}`",
                f"- content_type_counts: `{json.dumps(page.get('content_type_counts', {}), ensure_ascii=False)}`",
                "",
                "## Reading Text",
                "",
            ]
        )
        if page["text"]:
            lines.append(page["text"])
        else:
            lines.append("_No extractable running text on this page._")

        try:
            reference_markdown = safe_text(
                document.export_to_markdown(
                    page_no=page["docling_page_number"],
                    image_mode=ImageRefMode.REFERENCED,
                    traverse_pictures=True,
                )
            )
        except Exception:  # noqa: BLE001
            reference_markdown = ""

        formula_texts = [
            block["text"]
            for block in page_blocks
            if block["content_type"] == "formula" and block.get("text")
        ]
        reference_markdown = inject_formula_fallbacks(
            reference_markdown=reference_markdown,
            formula_texts=formula_texts,
        )

        fallback_media_refs = assign_fallback_media_refs(
            page_blocks=page_blocks,
            reference_markdown=reference_markdown,
        )

        lines.extend(["", "## Ordered Blocks", ""])
        if not page_blocks:
            lines.append("_No blocks extracted on this page._")
        for block in page_blocks:
            lines.extend(
                render_block_markdown(
                    block,
                    fallback_media_refs=fallback_media_refs.get(block["block_id"], []),
                )
            )

        lines.extend(["", "## Docling Reference Markdown", ""])
        if reference_markdown:
            lines.append(reference_markdown)
        else:
            lines.append("_Docling returned empty page markdown for this page._")

        rendered[page_number] = "\n".join(lines).strip() + "\n"

    return rendered


def build_section_markdown(
    sections: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
) -> dict[str, str]:
    blocks_by_id = {block["block_id"]: block for block in blocks}
    section_markdown: dict[str, str] = {}

    for section in sections:
        heading_prefix = "#" * max(1, min(section["heading_level"], 6))
        lines = [
            f"{heading_prefix} {section['title']}",
            "",
            "## Section Metadata",
            "",
            f"- section_id: `{section['section_id']}`",
            f"- heading_path: `{ ' > '.join(section['heading_path']) }`",
            f"- page_span: `{section['page_span']}`",
            f"- block_count: `{section.get('block_count', 0)}`",
            f"- content_types: `{json.dumps(section.get('content_types', {}), ensure_ascii=False)}`",
            "",
            "## Section Content",
        ]
        for block_id in section["block_ids"]:
            block = blocks_by_id[block_id]
            if not block["text"]:
                continue
            if block["block_id"] == section["block_ids"][0] and is_heading_type(block["content_type"]):
                continue
            lines.append("")
            lines.append(f"### {block['content_type']} (block `{block['block_id']}`)")
            lines.append("")
            lines.append(block["text"])
        section_markdown[section["section_id"]] = "\n".join(lines).strip() + "\n"

    return section_markdown


def render_block_markdown(
    block: dict[str, Any],
    fallback_media_refs: list[str] | None = None,
) -> list[str]:
    bbox = extract_primary_bbox(block)
    section_path = " > ".join(block.get("section_heading_path", []))
    lines = [
        f"### Block {block['page_block_order']:03d} | {block['content_type']}",
        "",
        f"- block_id: `{block['block_id']}`",
        f"- global_order: `{block['global_order']}`",
        f"- section_path: `{section_path}`",
        f"- docling_item_type: `{block['layout'].get('docling_item_type')}`",
        f"- self_ref: `{block['layout'].get('self_ref')}`",
    ]

    if bbox:
        lines.append(f"- bbox: `{json.dumps(bbox, ensure_ascii=False)}`")

    captions = block.get("captions") or []
    if captions:
        lines.append(f"- captions: `{json.dumps(captions, ensure_ascii=False)}`")

    if block.get("text"):
        lines.extend(["", "```text", block["text"], "```"])

    media_refs = block.get("media_refs") or fallback_media_refs or []
    if block["content_type"] == "figure":
        lines.extend(["", "#### Visual References"])
        if media_refs:
            for index, media_ref in enumerate(media_refs, start=1):
                lines.append(f"- figure_asset_{index}: `{media_ref}`")
                if media_ref.startswith("data:"):
                    lines.append("_Inline image omitted in markdown preview (data URI)._")
                else:
                    lines.append(f"![figure-{block['page_block_order']}-{index}]({media_ref})")
        else:
            lines.append(
                "- figure_asset: `_missing_` (enable `--picture-images` or use bbox to crop from page image)"
            )

    return lines + [""]


def assign_fallback_media_refs(
    *,
    page_blocks: list[dict[str, Any]],
    reference_markdown: str,
) -> dict[str, list[str]]:
    if not reference_markdown:
        return {}

    links = [normalize_media_ref(item) for item in MARKDOWN_IMAGE_PATTERN.findall(reference_markdown)]
    links = [item for item in links if item]
    if not links:
        return {}

    mapping: dict[str, list[str]] = {}
    link_index = 0
    for block in page_blocks:
        if block["content_type"] != "figure":
            continue
        if block.get("media_refs"):
            continue
        if link_index >= len(links):
            break
        mapping[block["block_id"]] = [links[link_index]]
        link_index += 1
    return mapping


def inject_formula_fallbacks(
    *,
    reference_markdown: str,
    formula_texts: list[str],
) -> str:
    marker = "<!-- formula-not-decoded -->"
    if marker not in reference_markdown:
        return reference_markdown

    if not formula_texts:
        return reference_markdown.replace(
            marker,
            "`[formula not decoded by docling; no normalized fallback text available]`",
        )

    rendered = reference_markdown
    for formula_text in formula_texts:
        if marker not in rendered:
            break
        replacement = f"```text\n{formula_text}\n```"
        rendered = rendered.replace(marker, replacement, 1)
    return rendered.replace(
        marker,
        "`[formula decoded in normalized blocks; no additional formula text found for this marker]`",
    )


def infer_document_title(
    raw_document: dict[str, Any],
    blocks: list[dict[str, Any]],
    source_path: Path,
) -> str:
    for block in blocks:
        if block["content_type"] in {"document_title", "heading"} and block["page_number"] == 1:
            return block["text"]

    return safe_text(raw_document.get("name")) or source_path.stem


def get_or_create_page_section(
    *,
    cache: dict[int, dict[str, Any]],
    sections: list[dict[str, Any]],
    document_id: str,
    source_filename: str,
    page_number: int | None,
) -> dict[str, Any]:
    if page_number in cache:
        return cache[page_number]

    page_token = page_number if page_number is not None else 0
    section_id = f"{document_id}:section:page-{page_token:04d}"
    section = {
        "section_id": section_id,
        "document_id": document_id,
        "title": f"Page {page_token}",
        "heading_level": 1,
        "heading_path": [f"Page {page_token}"],
        "slug_path": [f"page-{page_token:04d}"],
        "source_filename": source_filename,
        "page_start": page_token,
        "page_end": page_token,
        "block_ids": [],
        "text": "",
        "is_synthetic": True,
        "order": len(sections) + 1,
    }
    sections.append(section)
    cache[page_number] = section
    return section


def extract_provenance(item: Any) -> list[dict[str, Any]]:
    provenances = []
    for prov in getattr(item, "prov", None) or []:
        payload = prov.model_dump(mode="json") if hasattr(prov, "model_dump") else dict(vars(prov))
        provenances.append(
            {
                "page_number": payload.get("page_no"),
                "bbox": payload.get("bbox"),
                "charspan": payload.get("charspan"),
            }
        )
    return provenances


def extract_primary_bbox(block: dict[str, Any]) -> dict[str, Any] | None:
    provenance = block.get("layout", {}).get("provenance") or []
    if not provenance:
        return None
    return provenance[0].get("bbox")


def extract_media_refs(raw_entry: Any) -> list[str]:
    if not isinstance(raw_entry, dict):
        return []

    refs: list[str] = []

    def add(candidate: Any) -> None:
        if not isinstance(candidate, str):
            return
        normalized = normalize_media_ref(candidate)
        if normalized and normalized not in refs:
            refs.append(normalized)

    direct_keys = (
        "image_uri",
        "image_path",
        "asset_path",
        "uri",
        "path",
    )
    for key in direct_keys:
        add(raw_entry.get(key))

    image_payload = raw_entry.get("image")
    if isinstance(image_payload, str):
        add(image_payload)
    if isinstance(image_payload, dict):
        for key in ("uri", "path", "file", "relative_path", "src"):
            add(image_payload.get(key))

    for collection in ("images", "assets"):
        payload = raw_entry.get(collection)
        if isinstance(payload, list):
            for item in payload:
                if isinstance(item, str):
                    add(item)
                elif isinstance(item, dict):
                    for key in ("uri", "path", "file", "relative_path", "src"):
                        add(item.get(key))

    return refs


def extract_ref_texts(raw_document: dict[str, Any], refs: Any) -> list[str]:
    if not isinstance(refs, list):
        return []

    texts: list[str] = []
    for ref in refs:
        ref_value = ref.get("$ref") if isinstance(ref, dict) else None
        target = lookup_ref(raw_document, safe_text(ref_value))
        if not isinstance(target, dict):
            continue
        text = (
            safe_text(target.get("text"))
            or safe_text(target.get("orig"))
            or safe_text(target.get("content"))
        )
        if text:
            texts.append(text)
    return texts


def normalize_media_ref(value: str) -> str:
    candidate = safe_text(value).replace("\\", "/").strip()
    if not candidate:
        return ""
    if candidate.startswith(("http://", "https://", "data:")):
        return candidate
    if candidate.startswith("../"):
        return candidate
    if candidate.startswith("./"):
        candidate = candidate[2:]
    if candidate.startswith("assets/"):
        return f"../{candidate}"
    if "/" not in candidate:
        return f"../assets/{candidate}"
    return f"../assets/{candidate.lstrip('/')}"


def classify_content_type(label: str, item_type: str) -> str:
    normalized = (label or item_type).lower()
    if normalized == "page_header":
        return "header"
    if normalized == "page_footer":
        return "footer"
    if "formula" in normalized:
        return "formula"
    if "code" in normalized:
        return "code"
    if "table" in normalized:
        return "table"
    if "picture" in normalized or "figure" in normalized:
        return "figure"
    if "caption" in normalized:
        return "caption"
    if "list" in normalized:
        return "list_item"
    if normalized in {"title", "document_title"}:
        return "document_title"
    if "section" in normalized or "heading" in normalized:
        return "heading"
    if "footer" in normalized:
        return "footer"
    if "footnote" in normalized:
        return "footnote"
    return "paragraph"


def is_heading_type(content_type: str) -> bool:
    return content_type in {"document_title", "heading"}


def extract_item_text(item: Any, raw_entry: Any) -> str:
    direct_text = safe_text(getattr(item, "text", ""))
    if direct_text:
        return direct_text

    if hasattr(item, "export_to_markdown"):
        try:
            markdown = safe_text(item.export_to_markdown())
            if markdown:
                return markdown
        except Exception:  # noqa: BLE001
            pass

    if isinstance(raw_entry, dict):
        for key in ("text", "content", "orig", "markdown", "md"):
            value = safe_text(raw_entry.get(key))
            if value:
                return value

    return ""


def lookup_ref(raw_document: dict[str, Any], self_ref: str) -> Any:
    if not self_ref or not self_ref.startswith("#/"):
        return None

    cursor: Any = raw_document
    for part in self_ref[2:].split("/"):
        if isinstance(cursor, dict):
            cursor = cursor.get(part)
            continue
        if isinstance(cursor, list):
            try:
                cursor = cursor[int(part)]
            except (ValueError, IndexError):
                return None
            continue
        return None
    return cursor


def unique_preserving_order(values):
    seen = set()
    result = []
    for value in values:
        if value in seen or value is None:
            continue
        seen.add(value)
        result.append(value)
    return result


def join_text(existing: str, new_text: str) -> str:
    if not existing:
        return new_text
    return f"{existing}\n\n{new_text}"


def simple_slug(value: str) -> str:
    return value.lower().replace(" ", "-")
