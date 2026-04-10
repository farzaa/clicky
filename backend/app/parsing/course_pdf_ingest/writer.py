from __future__ import annotations

import json
import re
from pathlib import Path

from docling_core.types.doc import ImageRefMode

from .config import ParseConfig
from .models import ParsedArtifacts
from .ocr_fallback import maybe_write_ocr_markdown
from .utils import ensure_directory, write_json


def write_artifacts(
    artifacts: ParsedArtifacts,
    document,
    logger=None,
    config: ParseConfig | None = None,
) -> None:
    raw_dir = ensure_directory(artifacts.output_dir / "raw")
    normalized_dir = ensure_directory(artifacts.output_dir / "normalized")
    exports_dir = ensure_directory(artifacts.output_dir / "exports")
    pages_dir = ensure_directory(artifacts.output_dir / "pages")
    sections_dir = ensure_directory(artifacts.output_dir / "sections")
    asset_dir = ensure_directory(artifacts.output_dir / "assets")

    document.save_as_json(
        raw_dir / "docling.json",
        artifacts_dir=asset_dir,
        image_mode=ImageRefMode.REFERENCED,
    )
    document.save_as_markdown(
        exports_dir / "document.md",
        artifacts_dir=asset_dir,
        image_mode=ImageRefMode.REFERENCED,
        page_break_placeholder="\n\n---\n\n",
    )

    rewrite_figure_links_in_page_markdown(
        artifacts=artifacts,
        asset_dir=asset_dir,
    )

    ocr_result = maybe_write_ocr_markdown(
        artifacts=artifacts,
        asset_dir=asset_dir,
        logger=logger or _NullLogger(),
        config=config,
    )
    if ocr_result:
        artifacts.metadata.setdefault("processing", {})
        artifacts.metadata["processing"]["ocr_fallback"] = {
            "enabled": True,
            "status": "success",
            "trigger_reason": ocr_result.trigger_reason,
            "engines_used": ocr_result.engines_used,
            "written_markdown_path": str(ocr_result.output_path),
            "export_markdown_path": str(ocr_result.export_path),
            "total_pages": ocr_result.total_pages,
            "extracted_pages": ocr_result.extracted_pages,
            "injected_pages": ocr_result.injected_pages,
        }
    else:
        artifacts.metadata.setdefault("processing", {})
        artifacts.metadata["processing"]["ocr_fallback"] = {
            "enabled": True,
            "status": "skipped_or_unavailable",
        }

    (exports_dir / "document.agent.md").write_text(
        build_agent_document_markdown(artifacts.normalized_document),
        encoding="utf-8",
    )

    write_json(artifacts.output_dir / "metadata.json", artifacts.metadata)
    write_json(normalized_dir / "document.json", artifacts.normalized_document)

    for page in artifacts.normalized_document["pages"]:
        page_number = page["page_number"]
        stem = f"page-{page_number:04d}"
        write_json(pages_dir / f"{stem}.json", page)
        (pages_dir / f"{stem}.md").write_text(
            artifacts.page_markdown[page_number],
            encoding="utf-8",
        )

    for section in artifacts.normalized_document["sections"]:
        stem = section["section_id"].split(":")[-1].replace("/", "-")
        write_json(sections_dir / f"{stem}.json", section)
        (sections_dir / f"{stem}.md").write_text(
            artifacts.section_markdown[section["section_id"]],
            encoding="utf-8",
        )


class _NullLogger:
    def warning(self, *_args, **_kwargs) -> None:
        return


def rewrite_figure_links_in_page_markdown(*, artifacts: ParsedArtifacts, asset_dir: Path) -> None:
    figure_asset_map = build_figure_asset_map(
        blocks=artifacts.normalized_document.get("blocks", []),
        asset_dir=asset_dir,
    )
    if not figure_asset_map:
        return

    for page in artifacts.normalized_document.get("pages", []):
        page_number = page["page_number"]
        markdown = artifacts.page_markdown.get(page_number)
        if not markdown:
            continue
        rewritten = rewrite_data_uri_lines(
            markdown=markdown,
            figure_asset_map=figure_asset_map,
        )
        artifacts.page_markdown[page_number] = rewritten


def build_figure_asset_map(*, blocks: list[dict], asset_dir: Path) -> dict[str, str]:
    asset_files = sorted(asset_dir.glob("image_*.png"))
    if not asset_files:
        return {}

    figure_blocks = [block for block in blocks if block.get("content_type") == "figure"]
    if not figure_blocks:
        return {}

    indexed_blocks: list[tuple[int, dict]] = []
    fallback_blocks: list[dict] = []
    for block in figure_blocks:
        self_ref = str(block.get("layout", {}).get("self_ref", ""))
        match = re.fullmatch(r"#/pictures/(\d+)", self_ref)
        if match:
            indexed_blocks.append((int(match.group(1)), block))
        else:
            fallback_blocks.append(block)

    mapping: dict[str, str] = {}

    used_asset_indexes: set[int] = set()
    for picture_index, block in indexed_blocks:
        if picture_index >= len(asset_files):
            continue
        mapping[block["block_id"]] = f"../assets/{asset_files[picture_index].name}"
        used_asset_indexes.add(picture_index)

    unused_assets = [
        asset
        for index, asset in enumerate(asset_files)
        if index not in used_asset_indexes
    ]
    unresolved_blocks = [block for block in figure_blocks if block["block_id"] not in mapping]
    for block, asset in zip(unresolved_blocks, unused_assets):
        mapping[block["block_id"]] = f"../assets/{asset.name}"

    return mapping


def rewrite_data_uri_lines(*, markdown: str, figure_asset_map: dict[str, str]) -> str:
    lines = markdown.splitlines()
    current_block_id = ""

    for index, line in enumerate(lines):
        block_match = re.match(r"- block_id: `([^`]+)`", line)
        if block_match:
            current_block_id = block_match.group(1)
            continue

        if "figure_asset_" in line and "`data:image" in line and current_block_id:
            asset_ref = figure_asset_map.get(current_block_id)
            if not asset_ref:
                continue
            prefix = line.split("`", 1)[0].rstrip()
            lines[index] = f"{prefix} `{asset_ref}`"

            if index + 1 < len(lines) and lines[index + 1].startswith("_Inline image omitted"):
                lines[index + 1] = f"![{current_block_id}]({asset_ref})"
            else:
                lines.insert(index + 1, f"![{current_block_id}]({asset_ref})")

    return "\n".join(lines).strip() + "\n"


def build_agent_document_markdown(normalized_document: dict) -> str:
    document = normalized_document["document"]
    processing = normalized_document["processing"]
    pages = normalized_document.get("pages", [])
    toc = normalized_document.get("toc", [])

    lines = [
        f"# {document.get('title') or document['source_filename']}",
        "",
        "## Document Metadata",
        "",
        f"- document_id: `{document['document_id']}`",
        f"- source_filename: `{document['source_filename']}`",
        f"- source_path: `{document['source_path']}`",
        f"- page_count: `{document['page_count']}`",
        f"- parser_backend: `{processing.get('backend_used')}`",
        f"- profile: `{processing.get('profile')}`",
        f"- content_type_counts: `{json.dumps(processing.get('content_type_counts', {}), ensure_ascii=False)}`",
        "",
        "## TOC Preview",
        "",
    ]

    if toc:
        for node in toc[:40]:
            path = " > ".join(node.get("heading_path", [])) or node.get("title", "")
            lines.append(
                f"- `{path}` (pdf pages {node.get('page_start')} to {node.get('page_end')})"
            )
    else:
        lines.append("_No explicit TOC tree extracted._")

    lines.extend(["", "## Page Files", ""])
    if pages:
        for page in pages:
            page_number = page["page_number"]
            lines.append(
                f"- [page-{page_number:04d}.md](../pages/page-{page_number:04d}.md) "
                f"(book label `{page.get('book_page_label') or ''}`)"
            )
    else:
        lines.append("_No pages extracted._")

    return "\n".join(lines).strip() + "\n"
