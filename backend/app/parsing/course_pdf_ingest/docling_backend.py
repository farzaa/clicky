from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from docling.backend.docling_parse_backend import DoclingParseDocumentBackend
from docling.backend.pypdfium2_backend import PyPdfiumDocumentBackend
from docling.datamodel.base_models import ConversionStatus, InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions, RapidOcrOptions
from docling.document_converter import DocumentConverter, PdfFormatOption

from .config import BackendStrategy, ParseConfig

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")


@dataclass(slots=True)
class ConversionPayload:
    conversion_result: Any
    backend_used: str
    warnings: list[str]


def convert_with_docling(
    source_path: Path,
    config: ParseConfig,
    logger,
) -> ConversionPayload:
    warnings: list[str] = []
    backend_plan = iter_backends(config.backend, source_path)

    if config.backend is BackendStrategy.AUTO and backend_plan[0][0] == "pypdfium2":
        warning = (
            "Auto backend selected pypdfium2 first because the source path contains "
            "non-ASCII characters, which currently breaks docling-parse in this setup."
        )
        warnings.append(warning)
        logger.info(warning)

    for backend_name, backend_cls in backend_plan:
        try:
            logger.info("Attempting Docling conversion with backend=%s", backend_name)
            converter = DocumentConverter(
                format_options={
                    InputFormat.PDF: PdfFormatOption(
                        backend=backend_cls,
                        pipeline_options=build_pipeline_options(config),
                    )
                }
            )
            conversion_result = converter.convert(source_path)
            if conversion_result.status not in {
                ConversionStatus.SUCCESS,
                ConversionStatus.PARTIAL_SUCCESS,
            }:
                raise RuntimeError(
                    f"Docling returned non-success status: {conversion_result.status}"
                )

            return ConversionPayload(
                conversion_result=conversion_result,
                backend_used=backend_name,
                warnings=warnings,
            )
        except Exception as exc:  # noqa: BLE001
            message = f"{backend_name} backend failed: {exc}"
            warnings.append(message)
            logger.warning(message)
            if config.backend is not BackendStrategy.AUTO:
                raise

    raise RuntimeError(
        "All configured Docling backends failed. See warnings for details."
    )


def build_pipeline_options(config: ParseConfig) -> PdfPipelineOptions:
    options = PdfPipelineOptions()
    options.enable_remote_services = False
    options.document_timeout = config.document_timeout
    options.do_ocr = config.enable_ocr
    options.do_table_structure = True
    options.do_code_enrichment = config.enable_code_enrichment
    options.do_formula_enrichment = config.enable_formula_enrichment
    options.generate_page_images = config.generate_page_images
    options.generate_picture_images = config.generate_picture_images
    options.generate_parsed_pages = True

    if config.enable_code_enrichment or config.enable_formula_enrichment:
        options.code_formula_options.extract_code = config.enable_code_enrichment
        options.code_formula_options.extract_formulas = config.enable_formula_enrichment

    if config.enable_ocr and config.ocr_langs:
        options.ocr_options = RapidOcrOptions(lang=config.ocr_langs)

    return options


def iter_backends(strategy: BackendStrategy, source_path: Path) -> list[tuple[str, type]]:
    if strategy is BackendStrategy.DOCLING_PARSE:
        return [("docling-parse", DoclingParseDocumentBackend)]
    if strategy is BackendStrategy.PYPDFIUM:
        return [("pypdfium2", PyPdfiumDocumentBackend)]
    if contains_non_ascii(source_path):
        return [
            ("pypdfium2", PyPdfiumDocumentBackend),
            ("docling-parse", DoclingParseDocumentBackend),
        ]
    return [
        ("docling-parse", DoclingParseDocumentBackend),
        ("pypdfium2", PyPdfiumDocumentBackend),
    ]


def contains_non_ascii(path: Path) -> bool:
    try:
        str(path).encode("ascii")
        return False
    except UnicodeEncodeError:
        return True
