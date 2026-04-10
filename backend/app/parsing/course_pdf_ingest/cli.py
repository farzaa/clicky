from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from .config import BackendStrategy, OcrProvider, ParseConfig, ProfileName
from .logging_utils import setup_logging
from .pipeline import parse_file, parse_folder


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    log_file = Path(args.log_file).resolve() if args.log_file else None
    setup_logging(level=args.log_level, log_file=log_file)
    logger = logging.getLogger("course_pdf_ingest")

    config = ParseConfig.from_profile(
        profile=ProfileName(args.profile),
        backend=BackendStrategy(args.backend),
        ocr_provider=OcrProvider(args.ocr_provider),
        generate_page_images=args.page_images,
        generate_picture_images=args.picture_images,
        enable_ocr=args.ocr,
        enable_code_enrichment=args.code_enrichment,
        enable_formula_enrichment=args.formula_enrichment,
        continue_on_error=args.continue_on_error,
        recursive=args.recursive,
        glob_pattern=args.glob,
        output_root=Path(args.output).resolve(),
        ocr_langs=parse_csv_list(args.ocr_langs),
        document_timeout=args.document_timeout,
        single_markdown_only=args.single_markdown_only,
    )

    if args.command == "parse-file":
        result = parse_file(
            source_path=Path(args.input).resolve(),
            output_root=config.output_root,
            config=config,
            logger=logger,
        )
        print(json.dumps(result, indent=2))
        return

    if args.command == "parse-folder":
        result = parse_folder(
            input_dir=Path(args.input_dir).resolve(),
            output_root=config.output_root,
            config=config,
            logger=logger,
        )
        print(json.dumps(result, indent=2))
        return

    if args.command == "parse-topic":
        from .pipeline import parse_topic

        result = parse_topic(
            source_path=Path(args.input).resolve(),
            topic=args.topic,
            output_root=config.output_root,
            config=config,
            logger=logger,
            context_pages=args.context_pages,
            toc_scan_limit=args.toc_scan_limit,
            validation_window=args.validation_window,
        )
        print(json.dumps(result, indent=2))
        return

    parser.error(f"Unsupported command: {args.command}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="course-pdf-ingest",
        description="Parse and normalize technical-course PDFs with Docling.",
    )
    parser.add_argument("--output", default="artifacts", help="Root output directory.")
    parser.add_argument(
        "--profile",
        default=ProfileName.LIGHTWEIGHT.value,
        choices=[profile.value for profile in ProfileName],
        help="Preset parsing profile.",
    )
    parser.add_argument(
        "--backend",
        default=BackendStrategy.AUTO.value,
        choices=[backend.value for backend in BackendStrategy],
        help="PDF backend strategy.",
    )
    parser.add_argument(
        "--ocr",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Enable OCR support.",
    )
    parser.add_argument(
        "--ocr-langs",
        default="",
        help="Comma-separated OCR language hints for RapidOCR.",
    )
    parser.add_argument(
        "--ocr-provider",
        default=OcrProvider.RAPIDOCR.value,
        choices=[provider.value for provider in OcrProvider],
        help=(
            "OCR provider for OCR fallback markdown extraction. "
            "'rapidocr' is local and default; 'mistral-ocr', 'olmocr', and 'glm-ocr' are optional."
        ),
    )
    parser.add_argument(
        "--page-images",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Generate page images in Docling artifacts.",
    )
    parser.add_argument(
        "--picture-images",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Generate extracted figure/picture images in Docling artifacts.",
    )
    parser.add_argument(
        "--code-enrichment",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Enable Docling code enrichment.",
    )
    parser.add_argument(
        "--formula-enrichment",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Enable Docling formula enrichment.",
    )
    parser.add_argument("--glob", default="*.pdf", help="Glob pattern for folder parsing.")
    parser.add_argument(
        "--recursive",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Recurse into subfolders when parsing a directory.",
    )
    parser.add_argument(
        "--continue-on-error",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Continue when a document fails during folder parsing.",
    )
    parser.add_argument(
        "--document-timeout",
        type=float,
        default=600.0,
        help="Maximum per-document processing time in seconds.",
    )
    parser.add_argument(
        "--single-markdown-only",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Bypass full artifact export and write only one OCR markdown file per PDF.",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity.",
    )
    parser.add_argument(
        "--log-file",
        default="",
        help="Optional file path for persistent logs.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    parse_file_parser = subparsers.add_parser("parse-file", help="Parse a single PDF file.")
    parse_file_parser.add_argument("input", help="Path to the PDF file.")

    parse_folder_parser = subparsers.add_parser(
        "parse-folder",
        help="Parse all matching PDFs in a folder.",
    )
    parse_folder_parser.add_argument("input_dir", help="Directory containing PDF files.")

    parse_topic_parser = subparsers.add_parser(
        "parse-topic",
        help="Use the table of contents to jump to a topic and parse only that page window.",
    )
    parse_topic_parser.add_argument("input", help="Path to the PDF file.")
    parse_topic_parser.add_argument("topic", help="Topic or section title to locate.")
    parse_topic_parser.add_argument(
        "--context-pages",
        type=int,
        default=1,
        help="How many pages before/after the target page to include in the parsed slice.",
    )
    parse_topic_parser.add_argument(
        "--toc-scan-limit",
        type=int,
        default=30,
        help="How many leading PDF pages to scan for a printed table of contents.",
    )
    parse_topic_parser.add_argument(
        "--validation-window",
        type=int,
        default=6,
        help="How many pages around the estimated target to search for a better local heading match.",
    )

    return parser


def parse_csv_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]
