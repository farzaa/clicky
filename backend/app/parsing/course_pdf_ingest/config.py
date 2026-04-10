from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class ProfileName(str, Enum):
    TECHNICAL = "technical"
    SLIDES = "slides"
    LIGHTWEIGHT = "lightweight"


class BackendStrategy(str, Enum):
    AUTO = "auto"
    DOCLING_PARSE = "docling-parse"
    PYPDFIUM = "pypdfium2"


class OcrProvider(str, Enum):
    RAPIDOCR = "rapidocr"
    OLMOCR = "olmocr"
    GLM_OCR = "glm-ocr"
    MISTRAL_OCR = "mistral-ocr"


@dataclass(slots=True)
class ParseConfig:
    profile: ProfileName
    backend: BackendStrategy
    ocr_provider: OcrProvider
    enable_ocr: bool
    enable_code_enrichment: bool
    enable_formula_enrichment: bool
    generate_page_images: bool
    generate_picture_images: bool
    continue_on_error: bool
    recursive: bool
    glob_pattern: str
    output_root: Path
    ocr_langs: list[str]
    document_timeout: float
    single_markdown_only: bool

    @classmethod
    def from_profile(
        cls,
        profile: ProfileName,
        backend: BackendStrategy,
        ocr_provider: OcrProvider,
        generate_page_images: bool | None,
        generate_picture_images: bool | None,
        enable_ocr: bool | None,
        enable_code_enrichment: bool | None,
        enable_formula_enrichment: bool | None,
        continue_on_error: bool,
        recursive: bool,
        glob_pattern: str,
        output_root: Path,
        ocr_langs: list[str],
        document_timeout: float,
        single_markdown_only: bool,
    ) -> "ParseConfig":
        defaults = profile_defaults(profile)
        return cls(
            profile=profile,
            backend=backend,
            ocr_provider=ocr_provider,
            enable_ocr=defaults["enable_ocr"] if enable_ocr is None else enable_ocr,
            enable_code_enrichment=(
                defaults["enable_code_enrichment"]
                if enable_code_enrichment is None
                else enable_code_enrichment
            ),
            enable_formula_enrichment=(
                defaults["enable_formula_enrichment"]
                if enable_formula_enrichment is None
                else enable_formula_enrichment
            ),
            generate_page_images=(
                defaults["generate_page_images"]
                if generate_page_images is None
                else generate_page_images
            ),
            generate_picture_images=(
                defaults["generate_picture_images"]
                if generate_picture_images is None
                else generate_picture_images
            ),
            continue_on_error=continue_on_error,
            recursive=recursive,
            glob_pattern=glob_pattern,
            output_root=output_root,
            ocr_langs=ocr_langs,
            document_timeout=document_timeout,
            single_markdown_only=single_markdown_only,
        )


def profile_defaults(profile: ProfileName) -> dict[str, bool]:
    if profile == ProfileName.SLIDES:
        return {
            "enable_ocr": False,
            "enable_code_enrichment": False,
            "enable_formula_enrichment": False,
            "generate_page_images": False,
            "generate_picture_images": True,
        }

    if profile == ProfileName.LIGHTWEIGHT:
        return {
            "enable_ocr": False,
            "enable_code_enrichment": False,
            "enable_formula_enrichment": False,
            "generate_page_images": False,
            "generate_picture_images": True,
        }

    return {
        "enable_ocr": True,
        "enable_code_enrichment": True,
        "enable_formula_enrichment": True,
        "generate_page_images": False,
        "generate_picture_images": True,
    }
