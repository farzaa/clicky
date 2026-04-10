from __future__ import annotations

import base64
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
from statistics import mean, median
import subprocess
from tempfile import TemporaryDirectory
from typing import Any
import urllib.error
import urllib.request

from .config import OcrProvider, ParseConfig
from .models import ParsedArtifacts
from .utils import ensure_directory, safe_text, slugify


@dataclass(slots=True)
class OcrFallbackResult:
    output_path: Path
    export_path: Path
    total_pages: int
    extracted_pages: int
    injected_pages: int
    trigger_reason: str
    engines_used: list[str]


@dataclass(slots=True)
class PageOcrResult:
    page_number: int
    image_path: Path
    selected_profile: str
    selected_variant: str
    lines: list[str]
    formula_lines: list[str]
    scores: list[float]
    quality: float


_GLM_OCR_STATE: dict[str, Any] = {}
_OCR_PROVIDER_ALIASES = {
    "rapidocr": OcrProvider.RAPIDOCR.value,
    "rapid": OcrProvider.RAPIDOCR.value,
    "olmocr": OcrProvider.OLMOCR.value,
    "olm": OcrProvider.OLMOCR.value,
    "glm": OcrProvider.GLM_OCR.value,
    "glm-ocr": OcrProvider.GLM_OCR.value,
    "glm_ocr": OcrProvider.GLM_OCR.value,
    "mistral": OcrProvider.MISTRAL_OCR.value,
    "mistral-ocr": OcrProvider.MISTRAL_OCR.value,
    "mistral_ocr": OcrProvider.MISTRAL_OCR.value,
}


def write_single_markdown_for_pdf(
    *,
    source_path: Path,
    output_root: Path,
    config: ParseConfig,
    logger,
) -> dict[str, Any]:
    source_path = source_path.resolve()
    output_root = output_root.resolve()
    output_dir = output_root / f"{slugify(source_path.stem)}-written"
    ensure_directory(output_dir)
    clear_directory(output_dir)

    with TemporaryDirectory(prefix="course-pdf-ingest-ocr-") as temp_dir:
        temp_asset_dir = Path(temp_dir)
        page_numbers = list_pdf_page_numbers(source_path=source_path)
        if not page_numbers:
            raise RuntimeError("Unable to read PDF pages for OCR extraction.")

        page_image_map = render_pages_from_source_pdf(
            source_path=source_path,
            page_numbers=page_numbers,
            asset_dir=temp_asset_dir,
            logger=logger,
            scale=4.2,
        )
        page_results, engines_used, provider_used = run_page_ocr_with_provider(
            provider=normalize_provider(config),
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            source_path=source_path,
            logger=logger,
        )
        if not page_results:
            raise RuntimeError("OCR provider did not return text for any page.")

    markdown_name = f"{source_path.stem} written text markdown.md"
    markdown_path = output_dir / markdown_name
    payload = build_written_markdown(
        source_stem=source_path.stem,
        page_results=page_results,
        asset_prefix="",
        include_images=False,
    )
    markdown_path.write_text(payload, encoding="utf-8")

    return {
        "status": "success",
        "mode": "single_markdown_only",
        "source": str(source_path),
        "output_dir": str(output_dir),
        "markdown_path": str(markdown_path),
        "page_count": len(page_numbers),
        "extracted_pages": sum(1 for item in page_results.values() if item.lines),
        "engines_used": engines_used,
        "ocr_provider_requested": config.ocr_provider.value,
        "ocr_provider_used": provider_used,
    }


def clear_directory(path: Path) -> None:
    import shutil

    for child in path.iterdir():
        if child.is_dir():
            shutil.rmtree(child, ignore_errors=True)
        else:
            child.unlink(missing_ok=True)


def list_pdf_page_numbers(*, source_path: Path) -> list[int]:
    try:
        import pypdfium2 as pdfium

        pdf = pdfium.PdfDocument(str(source_path))
        return list(range(1, len(pdf) + 1))
    except Exception:  # noqa: BLE001
        return []


def maybe_write_ocr_markdown(
    *,
    artifacts: ParsedArtifacts,
    asset_dir: Path,
    logger,
    config: ParseConfig | None,
) -> OcrFallbackResult | None:
    pages = artifacts.normalized_document.get("pages", [])
    blocks = artifacts.normalized_document.get("blocks", [])
    if not pages or not blocks:
        return None

    should_run, trigger_reason = should_run_ocr_fallback(artifacts.normalized_document)
    if not should_run:
        return None

    page_image_map = build_page_image_map(
        artifacts=artifacts,
        asset_dir=asset_dir,
        logger=logger,
    )
    if not page_image_map:
        return None

    provider = normalize_provider(config)
    page_results, engines_used, provider_used = run_page_ocr_with_provider(
        provider=provider,
        page_numbers=[int(page.get("page_number")) for page in pages if page.get("page_number")],
        page_image_map=page_image_map,
        source_path=artifacts.source_path,
        logger=logger,
    )
    if not page_results:
        return None

    injected_pages = inject_ocr_text_into_pages(
        normalized_document=artifacts.normalized_document,
        page_markdown=artifacts.page_markdown,
        page_results=page_results,
    )

    source_filename = safe_text(
        artifacts.normalized_document.get("document", {}).get("source_filename")
    )
    source_stem = Path(source_filename or artifacts.source_path.name).stem

    payload_root = build_written_markdown(
        source_stem=source_stem,
        page_results=page_results,
        asset_prefix="./assets",
    )
    payload_export = build_written_markdown(
        source_stem=source_stem,
        page_results=page_results,
        asset_prefix="../assets",
    )

    output_path = artifacts.output_dir / f"{source_stem} written text markdown.md"
    export_path = artifacts.output_dir / "exports" / "document.ocr.md"
    output_path.write_text(payload_root, encoding="utf-8")
    export_path.write_text(payload_export, encoding="utf-8")

    return OcrFallbackResult(
        output_path=output_path,
        export_path=export_path,
        total_pages=len(pages),
        extracted_pages=sum(1 for item in page_results.values() if item.lines),
        injected_pages=injected_pages,
        trigger_reason=f"{trigger_reason}|provider={provider_used}",
        engines_used=engines_used,
    )


def should_run_ocr_fallback(normalized_document: dict[str, Any]) -> tuple[bool, str]:
    pages = normalized_document.get("pages", []) or []
    processing = normalized_document.get("processing", {}) or {}
    counts = processing.get("content_type_counts", {}) if isinstance(processing, dict) else {}
    if not pages:
        return False, "no_pages"

    empty_text_pages = 0
    total_chars = 0
    for page in pages:
        text = safe_text(page.get("text"))
        total_chars += len(text)
        if len(text) < 30:
            empty_text_pages += 1

    empty_ratio = empty_text_pages / max(len(pages), 1)
    paragraph_like = 0
    for key in ("paragraph", "heading", "document_title", "list_item", "formula"):
        paragraph_like += int(counts.get(key, 0))
    figure_count = int(counts.get("figure", 0))

    if total_chars < 300 and empty_ratio >= 0.35:
        return True, "low_text_density"
    if figure_count > 0 and paragraph_like == 0:
        return True, "figure_only_extraction"
    return False, "text_extraction_sufficient"


def build_page_image_map(
    *,
    artifacts: ParsedArtifacts,
    asset_dir: Path,
    logger,
) -> dict[int, Path]:
    page_numbers = sorted(
        {
            int(page.get("page_number"))
            for page in artifacts.normalized_document.get("pages", [])
            if isinstance(page.get("page_number"), int)
        }
    )
    if not page_numbers:
        return {}

    rendered = render_pages_from_source_pdf(
        source_path=artifacts.source_path,
        page_numbers=page_numbers,
        asset_dir=asset_dir,
        logger=logger,
        scale=3.5,
    )
    if rendered:
        return rendered

    figure_asset_map = build_figure_asset_map(
        blocks=artifacts.normalized_document.get("blocks", []),
        asset_dir=asset_dir,
    )
    return first_figure_asset_per_page(
        pages=artifacts.normalized_document.get("pages", []),
        blocks=artifacts.normalized_document.get("blocks", []),
        figure_asset_map=figure_asset_map,
    )


def render_pages_from_source_pdf(
    *,
    source_path: Path,
    page_numbers: list[int],
    asset_dir: Path,
    logger,
    scale: float,
) -> dict[int, Path]:
    try:
        import pypdfium2 as pdfium
    except Exception as exc:  # noqa: BLE001
        logger.warning("pypdfium2 not available for OCR rendering: %s", exc)
        return {}

    try:
        pdf = pdfium.PdfDocument(str(source_path))
    except Exception as exc:  # noqa: BLE001
        logger.warning("Unable to open PDF for OCR rendering: %s", exc)
        return {}

    page_count = len(pdf)
    result: dict[int, Path] = {}
    for page_number in page_numbers:
        if page_number < 1 or page_number > page_count:
            continue

        output_path = asset_dir / f"ocr_page_{page_number:04d}.png"
        if not output_path.exists():
            try:
                page = pdf[page_number - 1]
                bitmap = page.render(scale=scale)
                image = bitmap.to_pil()
                image.save(output_path)
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to render page %s for OCR: %s", page_number, exc)
                continue

        result[page_number] = output_path
    return result


def normalize_provider(config: ParseConfig | None) -> str:
    raw = ""
    if config is not None:
        raw = getattr(config, "ocr_provider", OcrProvider.RAPIDOCR).value
    value = safe_text(raw).lower().strip()
    return _OCR_PROVIDER_ALIASES.get(value, OcrProvider.RAPIDOCR.value)


def run_page_ocr_with_provider(
    *,
    provider: str,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    source_path: Path,
    logger,
) -> tuple[dict[int, PageOcrResult], list[str], str]:
    requested_provider = _OCR_PROVIDER_ALIASES.get(provider, OcrProvider.RAPIDOCR.value)

    if requested_provider == OcrProvider.MISTRAL_OCR.value:
        mistral_results, mistral_engine = run_mistral_ocr_api(
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            source_path=source_path,
            logger=logger,
        )
        if mistral_results:
            return mistral_results, [mistral_engine], OcrProvider.MISTRAL_OCR.value
        logger.warning("Mistral OCR did not return usable text; falling back to RapidOCR.")

    if requested_provider == OcrProvider.GLM_OCR.value:
        glm_results = run_glm_ocr_transformers(
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            logger=logger,
        )
        if glm_results:
            return glm_results, ["glm-ocr-transformers"], OcrProvider.GLM_OCR.value
        logger.warning("GLM OCR unavailable; trying command template and fallback providers.")

    if requested_provider in {OcrProvider.GLM_OCR.value, OcrProvider.OLMOCR.value}:
        template_results, command_name = run_command_template_ocr(
            provider=requested_provider,
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            source_path=source_path,
            logger=logger,
        )
        if template_results:
            return template_results, [command_name], requested_provider
        logger.warning(
            "OCR provider '%s' command template did not return results; falling back to RapidOCR.",
            requested_provider,
        )

    engines = build_rapidocr_engines(logger=logger)
    if not engines:
        return {}, [], requested_provider
    return (
        run_page_ocr(page_numbers=page_numbers, page_image_map=page_image_map, engines=engines),
        [name for name, _ in engines],
        OcrProvider.RAPIDOCR.value,
    )


def build_rapidocr_engines(*, logger) -> list[tuple[str, Any]]:
    try:
        from rapidocr import RapidOCR
        from rapidocr.utils.typings import LangCls, LangDet, LangRec, ModelType, OCRVersion
    except Exception as exc:  # noqa: BLE001
        logger.warning("RapidOCR is not available for fallback markdown: %s", exc)
        return []

    profiles = [
        (
            "v4_english",
            {
                "Det.lang_type": LangDet.EN,
                "Rec.lang_type": LangRec.EN,
                "Det.ocr_version": OCRVersion.PPOCRV4,
                "Rec.ocr_version": OCRVersion.PPOCRV4,
            },
        ),
        (
            "v4_multi_latin",
            {
                "Det.lang_type": LangDet.MULTI,
                "Rec.lang_type": LangRec.LATIN,
                "Det.ocr_version": OCRVersion.PPOCRV4,
                "Rec.ocr_version": OCRVersion.PPOCRV4,
            },
        ),
        (
            "v5_english",
            {
                "Det.lang_type": LangDet.CH,
                "Rec.lang_type": LangRec.EN,
                "Det.ocr_version": OCRVersion.PPOCRV5,
                "Rec.ocr_version": OCRVersion.PPOCRV5,
            },
        ),
    ]

    engines: list[tuple[str, Any]] = []
    for name, params in profiles:
        try:
            engine = RapidOCR(
                params={
                    "Global.text_score": 0.25,
                    "Det.model_type": ModelType.MOBILE,
                    "Rec.model_type": ModelType.MOBILE,
                    "Cls.lang_type": LangCls.CH,
                    **params,
                }
            )
            engines.append((name, engine))
        except Exception as exc:  # noqa: BLE001
            logger.warning("Unable to initialize OCR profile %s: %s", name, exc)
    return engines


def run_mistral_ocr_api(
    *,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    source_path: Path,
    logger,
) -> tuple[dict[int, PageOcrResult], str]:
    api_key = safe_text(os.getenv("MISTRAL_API_KEY")).strip()
    if not api_key:
        logger.warning("MISTRAL_API_KEY is not set. Unable to use mistral-ocr provider.")
        return {}, "mistral-ocr-api-key-missing"

    api_base = safe_text(os.getenv("MISTRAL_API_BASE", "https://api.mistral.ai")).strip()
    model_name = safe_text(os.getenv("MISTRAL_OCR_MODEL", "mistral-ocr-latest")).strip()
    include_image_base64 = safe_text(
        os.getenv("MISTRAL_OCR_INCLUDE_IMAGE_BASE64", "false")
    ).lower() in {"1", "true", "yes"}
    timeout_seconds = int(float(os.getenv("MISTRAL_OCR_TIMEOUT_SECONDS", "240")))
    page_zero_based = [max(0, page - 1) for page in sorted(set(page_numbers))]
    mode = safe_text(os.getenv("MISTRAL_OCR_MODE", "page-image")).lower().strip()
    endpoint = f"{api_base.rstrip('/')}/v1/ocr"

    if mode == "document-url":
        payload = {
            "model": model_name,
            "document": {"type": "document_url", "document_url": source_path.resolve().as_uri()},
            "pages": page_zero_based,
            "include_image_base64": include_image_base64,
            "extract_header": True,
            "extract_footer": True,
            "confidence_scores_granularity": "page",
            "table_format": "markdown",
        }
        response_payload, error_code = post_mistral_ocr(
            endpoint=endpoint,
            api_key=api_key,
            payload=payload,
            timeout_seconds=timeout_seconds,
            logger=logger,
        )
        if response_payload:
            parsed = parse_mistral_ocr_payload(
                page_numbers=page_numbers,
                page_image_map=page_image_map,
                source_path=source_path,
                payload=response_payload,
                model_name=model_name,
            )
            if parsed:
                return parsed, f"mistral-ocr:{model_name}:document-url"
        logger.warning(
            "Mistral document-url OCR mode returned no usable text (status=%s).",
            error_code,
        )

    return (
        run_mistral_page_image_mode(
            endpoint=endpoint,
            api_key=api_key,
            model_name=model_name,
            page_numbers=page_numbers,
            page_image_map=page_image_map,
            source_path=source_path,
            include_image_base64=include_image_base64,
            timeout_seconds=timeout_seconds,
            logger=logger,
        ),
        f"mistral-ocr:{model_name}:page-image",
    )


def run_mistral_page_image_mode(
    *,
    endpoint: str,
    api_key: str,
    model_name: str,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    source_path: Path,
    include_image_base64: bool,
    timeout_seconds: int,
    logger,
) -> dict[int, PageOcrResult]:
    results: dict[int, PageOcrResult] = {}
    for page_number in page_numbers:
        image_path = page_image_map.get(page_number)
        if not image_path or not image_path.exists():
            continue
        data_url = image_path_to_data_url(image_path=image_path)
        if not data_url:
            continue

        payload = {
            "model": model_name,
            "document": {"type": "image_url", "image_url": data_url},
            "include_image_base64": include_image_base64,
            "extract_header": True,
            "extract_footer": True,
            "confidence_scores_granularity": "page",
            "table_format": "markdown",
        }
        response_payload, _ = post_mistral_ocr(
            endpoint=endpoint,
            api_key=api_key,
            payload=payload,
            timeout_seconds=timeout_seconds,
            logger=logger,
        )
        if not response_payload:
            continue
        single_page = parse_mistral_ocr_payload(
            page_numbers=[page_number],
            page_image_map={page_number: image_path},
            source_path=source_path,
            payload=response_payload,
            model_name=model_name,
        )
        if single_page.get(page_number):
            results[page_number] = single_page[page_number]

    return results


def image_path_to_data_url(*, image_path: Path) -> str:
    suffix = image_path.suffix.lower()
    mime = "image/png"
    if suffix in {".jpg", ".jpeg"}:
        mime = "image/jpeg"
    elif suffix == ".webp":
        mime = "image/webp"
    try:
        encoded = base64.b64encode(image_path.read_bytes()).decode("ascii")
    except Exception:  # noqa: BLE001
        return ""
    return f"data:{mime};base64,{encoded}"


def post_mistral_ocr(
    *,
    endpoint: str,
    api_key: str,
    payload: dict[str, Any],
    timeout_seconds: int,
    logger,
) -> tuple[dict[str, Any] | None, str]:
    request = urllib.request.Request(
        url=endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        details = safe_text(exc.read().decode("utf-8", errors="replace"))
        logger.warning("Mistral OCR request failed with HTTP %s: %s", exc.code, details)
        return None, f"http-{exc.code}"
    except Exception as exc:  # noqa: BLE001
        logger.warning("Mistral OCR request failed: %s", exc)
        return None, "request-error"

    try:
        return json.loads(raw), "ok"
    except Exception as exc:  # noqa: BLE001
        logger.warning("Mistral OCR returned non-JSON payload: %s", exc)
        return None, "invalid-json"


def parse_mistral_ocr_payload(
    *,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    source_path: Path,
    payload: dict[str, Any],
    model_name: str,
) -> dict[int, PageOcrResult]:
    pages_payload = payload.get("pages")
    if not isinstance(pages_payload, list):
        return {}
    results: dict[int, PageOcrResult] = {}
    for position, page_payload in enumerate(pages_payload):
        if not isinstance(page_payload, dict):
            continue
        page_number = resolve_mistral_page_number(
            page_payload=page_payload,
            page_numbers=page_numbers,
            position=position,
        )
        if page_number not in page_numbers:
            continue
        markdown = safe_text(page_payload.get("markdown"))
        lines = parse_markdown_ocr_lines(markdown)
        if not lines:
            continue
        confidence = extract_mistral_page_confidence(page_payload)
        default_score = confidence if confidence is not None else 0.9
        scores = [default_score for _ in lines]
        quality = compute_ocr_quality(lines=lines, scores=scores)
        fallback_image = next(iter(page_image_map.values()), source_path)
        image_path = page_image_map.get(page_number) or fallback_image
        results[page_number] = PageOcrResult(
            page_number=page_number,
            image_path=image_path,
            selected_profile=OcrProvider.MISTRAL_OCR.value,
            selected_variant=model_name,
            lines=lines,
            formula_lines=extract_formula_like_lines(lines),
            scores=scores,
            quality=quality,
        )
    return results


def resolve_mistral_page_number(
    *,
    page_payload: dict[str, Any],
    page_numbers: list[int],
    position: int,
) -> int:
    raw_index = page_payload.get("index")
    if isinstance(raw_index, int):
        if raw_index in page_numbers:
            return raw_index
        if (raw_index + 1) in page_numbers:
            return raw_index + 1
    if 0 <= position < len(page_numbers):
        return page_numbers[position]
    return page_numbers[0]


def extract_mistral_page_confidence(page_payload: dict[str, Any]) -> float | None:
    confidence_scores = page_payload.get("confidence_scores")
    if isinstance(confidence_scores, dict):
        avg = confidence_scores.get("average_page_confidence_score")
        if isinstance(avg, (int, float)):
            return float(avg)
    return None


def parse_markdown_ocr_lines(payload: str) -> list[str]:
    if not payload:
        return []
    normalized = payload.replace("\r\n", "\n").replace("<br>", "\n")
    cleaned: list[str] = []
    for raw_line in normalized.split("\n"):
        line = normalize_ocr_line(raw_line)
        if not line:
            continue
        line = re.sub(r"^#{1,6}\s*", "", line)
        line = line.replace("**", "").replace("__", "")
        line = line.replace("`", "")
        line = re.sub(r"!\[[^\]]*\]\([^)]+\)", "", line)
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        line = normalize_ocr_line(line)
        if not line:
            continue
        cleaned.append(line)

    return dedupe_lines(cleaned)


def run_command_template_ocr(
    *,
    provider: str,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    source_path: Path,
    logger,
) -> tuple[dict[int, PageOcrResult], str]:
    env_key = (
        "COURSE_PDF_GLM_OCR_CMD_TEMPLATE"
        if provider == OcrProvider.GLM_OCR.value
        else "COURSE_PDF_OLMOCR_CMD_TEMPLATE"
    )
    template = safe_text(os.getenv(env_key)).strip()
    if not template:
        return {}, f"{provider}-template-not-configured"

    timeout_seconds = int(float(os.getenv("COURSE_PDF_OCR_CMD_TIMEOUT_SECONDS", "180")))
    results: dict[int, PageOcrResult] = {}
    for page_number in page_numbers:
        image_path = page_image_map.get(page_number)
        if not image_path or not image_path.exists():
            continue

        try:
            command = template.format(
                image=str(image_path),
                image_name=image_path.name,
                pdf=str(source_path),
                pdf_name=source_path.name,
                page=page_number,
            )
        except KeyError as exc:
            logger.warning(
                "Invalid OCR command template %s missing key %s",
                env_key,
                exc,
            )
            return {}, f"{provider}-template-invalid"

        try:
            completed = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                check=False,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("OCR command failed for page %s: %s", page_number, exc)
            continue

        text_payload = (
            completed.stdout.strip()
            if completed.stdout
            else safe_text(completed.stderr).strip()
        )
        lines = parse_external_ocr_lines(text_payload)
        if not lines:
            continue

        scores = [0.72 for _ in lines]
        quality = compute_ocr_quality(lines=lines, scores=scores)
        results[page_number] = PageOcrResult(
            page_number=page_number,
            image_path=image_path,
            selected_profile=provider,
            selected_variant="command_template",
            lines=lines,
            formula_lines=extract_formula_like_lines(lines),
            scores=scores,
            quality=quality,
        )

    return results, f"{provider}-command-template"


def parse_external_ocr_lines(payload: str) -> list[str]:
    if not payload:
        return []
    normalized = fix_common_mojibake(payload).replace("\r\n", "\n")
    normalized = normalized.replace("```markdown", "```").replace("```text", "```")
    lines: list[str] = []
    for raw_line in normalized.split("\n"):
        line = normalize_ocr_line(raw_line)
        if not line:
            continue
        if line == "```":
            continue
        if is_noise_token(text=line, score=0.7):
            continue
        lines.append(line)
    return dedupe_lines(lines)


def run_glm_ocr_transformers(
    *,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    logger,
) -> dict[int, PageOcrResult]:
    model_state = load_glm_ocr_state(logger=logger)
    if not model_state:
        return {}

    model = model_state["model"]
    processor = model_state["processor"]
    torch_mod = model_state["torch"]
    prompt = model_state["prompt"]
    max_new_tokens = model_state["max_new_tokens"]

    results: dict[int, PageOcrResult] = {}
    for page_number in page_numbers:
        image_path = page_image_map.get(page_number)
        if not image_path or not image_path.exists():
            continue

        file_uri = image_path.resolve().as_uri()
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "url": file_uri},
                    {"type": "text", "text": prompt},
                ],
            }
        ]
        try:
            inputs = processor.apply_chat_template(
                messages,
                tokenize=True,
                add_generation_prompt=True,
                return_dict=True,
                return_tensors="pt",
            )
            if hasattr(model, "device"):
                for key, value in list(inputs.items()):
                    if hasattr(value, "to"):
                        inputs[key] = value.to(model.device)
            with torch_mod.inference_mode():
                output = model.generate(**inputs, max_new_tokens=max_new_tokens)
            decoded = processor.decode(output[0], skip_special_tokens=True)
        except Exception as exc:  # noqa: BLE001
            logger.warning("GLM OCR inference failed on page %s: %s", page_number, exc)
            continue

        lines = parse_external_ocr_lines(strip_prompt_echo(decoded, prompt=prompt))
        if not lines:
            continue
        scores = [0.75 for _ in lines]
        quality = compute_ocr_quality(lines=lines, scores=scores)
        results[page_number] = PageOcrResult(
            page_number=page_number,
            image_path=image_path,
            selected_profile=OcrProvider.GLM_OCR.value,
            selected_variant="transformers",
            lines=lines,
            formula_lines=extract_formula_like_lines(lines),
            scores=scores,
            quality=quality,
        )

    return results


def load_glm_ocr_state(*, logger) -> dict[str, Any] | None:
    if _GLM_OCR_STATE:
        return _GLM_OCR_STATE
    enable_transformers = safe_text(os.getenv("GLM_OCR_ENABLE_TRANSFORMERS")).lower().strip()
    if enable_transformers not in {"1", "true", "yes"}:
        logger.warning(
            "GLM transformers path disabled. Set GLM_OCR_ENABLE_TRANSFORMERS=1 to enable local GLM-OCR model loading."
        )
        return None
    try:
        import torch
        from transformers import AutoProcessor, GlmOcrForConditionalGeneration
    except Exception as exc:  # noqa: BLE001
        logger.warning("GLM OCR dependencies missing: %s", exc)
        return None

    model_id = os.getenv("GLM_OCR_MODEL_ID", "zai-org/GLM-OCR")
    max_new_tokens = int(float(os.getenv("GLM_OCR_MAX_NEW_TOKENS", "1024")))
    prompt = os.getenv(
        "GLM_OCR_PROMPT",
        "Extract all readable text, formulas, and table content faithfully.",
    )
    device_map = os.getenv("GLM_OCR_DEVICE_MAP", "auto")
    dtype_name = os.getenv("GLM_OCR_DTYPE", "bfloat16").strip()
    torch_dtype = getattr(torch, dtype_name, None)
    kwargs: dict[str, Any] = {"device_map": device_map}
    if torch_dtype is not None:
        kwargs["torch_dtype"] = torch_dtype

    try:
        processor = AutoProcessor.from_pretrained(model_id)
        model = GlmOcrForConditionalGeneration.from_pretrained(model_id, **kwargs)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Unable to load GLM OCR model '%s': %s", model_id, exc)
        return None

    _GLM_OCR_STATE.update(
        {
            "processor": processor,
            "model": model,
            "torch": torch,
            "prompt": prompt,
            "max_new_tokens": max_new_tokens,
        }
    )
    return _GLM_OCR_STATE


def strip_prompt_echo(value: str, *, prompt: str) -> str:
    text = safe_text(value).strip()
    if not text:
        return ""
    prompt_norm = safe_text(prompt).strip()
    if prompt_norm and text.lower().startswith(prompt_norm.lower()):
        return text[len(prompt_norm) :].strip()
    return text


def run_page_ocr(
    *,
    page_numbers: list[int],
    page_image_map: dict[int, Path],
    engines: list[tuple[str, Any]],
) -> dict[int, PageOcrResult]:
    try:
        import cv2
    except Exception:  # noqa: BLE001
        cv2 = None

    results: dict[int, PageOcrResult] = {}
    for page_number in page_numbers:
        image_path = page_image_map.get(page_number)
        if not image_path or not image_path.exists():
            continue

        variants = build_image_variants(image_path=image_path, cv2=cv2)
        if not variants:
            continue
        best_result: PageOcrResult | None = None

        # First pass: original image across all profiles.
        scored_original: list[tuple[float, str, Any, list[str], list[float]]] = []
        for profile_name, engine in engines:
            output = safe_engine_call(engine, variants["original"])
            lines, scores = extract_sorted_lines(output)
            quality = compute_ocr_quality(lines=lines, scores=scores)
            scored_original.append((quality, profile_name, engine, lines, scores))
            if best_result is None or quality > best_result.quality:
                best_result = PageOcrResult(
                    page_number=page_number,
                    image_path=image_path,
                    selected_profile=profile_name,
                    selected_variant="original",
                    lines=dedupe_lines(lines),
                    formula_lines=extract_formula_like_lines(lines),
                    scores=scores,
                    quality=quality,
                )

        # Progressive refinement only when quality is weak.
        scored_original.sort(key=lambda item: item[0], reverse=True)
        top_profiles = scored_original[:2]
        best_quality = best_result.quality if best_result else -1.0
        refinement_variants: list[str] = []
        if best_quality < 0.82 and "gray_otsu" in variants:
            refinement_variants.append("gray_otsu")
        if best_quality < 0.74 and "clahe_sharp" in variants:
            refinement_variants.append("clahe_sharp")

        for variant_name in refinement_variants:
            variant_image = variants[variant_name]
            for _, profile_name, engine, _, _ in top_profiles:
                output = safe_engine_call(engine, variant_image)
                lines, scores = extract_sorted_lines(output)
                quality = compute_ocr_quality(lines=lines, scores=scores)
                if best_result is None or quality > best_result.quality:
                    best_result = PageOcrResult(
                        page_number=page_number,
                        image_path=image_path,
                        selected_profile=profile_name,
                        selected_variant=variant_name,
                        lines=dedupe_lines(lines),
                        formula_lines=extract_formula_like_lines(lines),
                        scores=scores,
                        quality=quality,
                    )

        if best_result:
            results[page_number] = best_result

    return results


def safe_engine_call(engine: Any, image: Any) -> Any:
    try:
        return engine(image)
    except Exception:  # noqa: BLE001
        class Empty:
            txts = ()
            scores = ()
            boxes = None

        return Empty()


def build_image_variants(*, image_path: Path, cv2: Any) -> dict[str, Any]:
    if cv2 is None:
        return {"original": str(image_path)}

    image = read_image_with_unicode_path(image_path=image_path, cv2=cv2)
    if image is None:
        return {"original": str(image_path)}

    variants: dict[str, Any] = {"original": image}
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)

    otsu = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
    variants["gray_otsu"] = otsu

    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    sharp = cv2.GaussianBlur(clahe, (0, 0), 1.0)
    sharp = cv2.addWeighted(clahe, 1.5, sharp, -0.5, 0)
    variants["clahe_sharp"] = sharp

    return variants


def read_image_with_unicode_path(*, image_path: Path, cv2: Any):
    try:
        import numpy as np

        raw = np.fromfile(str(image_path), dtype=np.uint8)
        if raw.size == 0:
            return None
        return cv2.imdecode(raw, cv2.IMREAD_COLOR)
    except Exception:  # noqa: BLE001
        return None


def extract_sorted_lines(output: Any) -> tuple[list[str], list[float]]:
    raw_texts = list(getattr(output, "txts", None) or [])
    raw_scores = list(getattr(output, "scores", None) or [])
    raw_boxes_obj = getattr(output, "boxes", None)
    if raw_boxes_obj is None:
        raw_boxes = []
    else:
        raw_boxes = list(raw_boxes_obj)

    entries = []
    for idx, text in enumerate(raw_texts):
        normalized = normalize_ocr_line(text)
        if not normalized:
            continue
        score = float(raw_scores[idx]) if idx < len(raw_scores) else 0.0
        if is_noise_token(text=normalized, score=score):
            continue
        box = raw_boxes[idx] if idx < len(raw_boxes) else None
        y_center, x_min, height = extract_box_metrics(box)
        entries.append((y_center, x_min, height, normalized, score))

    if not entries:
        return [], []

    entries.sort(key=lambda item: (item[0], item[1]))
    line_tol = max(10.0, median(item[2] for item in entries if item[2] > 0) * 0.65)
    line_entries = merge_entries_to_lines(entries=entries, line_tol=line_tol)
    lines = [entry[0] for entry in line_entries if entry[0]]
    scores = [entry[1] for entry in line_entries if entry[0]]
    return lines, scores


def extract_box_metrics(box: Any) -> tuple[float, float, float]:
    if box is None:
        return (0.0, 0.0, 0.0)
    try:
        points = list(box)
        xs = [float(point[0]) for point in points]
        ys = [float(point[1]) for point in points]
        return ((min(ys) + max(ys)) / 2.0, min(xs), max(ys) - min(ys))
    except Exception:  # noqa: BLE001
        return (0.0, 0.0, 0.0)


def merge_entries_to_lines(
    *,
    entries: list[tuple[float, float, float, str, float]],
    line_tol: float,
) -> list[tuple[str, float]]:
    grouped: list[list[tuple[float, float, float, str, float]]] = []
    for entry in entries:
        y_center, _, _, _, _ = entry
        if not grouped:
            grouped.append([entry])
            continue
        last_group = grouped[-1]
        ref_y = mean(item[0] for item in last_group)
        if abs(y_center - ref_y) <= line_tol:
            last_group.append(entry)
        else:
            grouped.append([entry])

    merged: list[tuple[str, float]] = []
    for group in grouped:
        group_sorted = sorted(group, key=lambda item: item[1])
        text = " ".join(item[3] for item in group_sorted).strip()
        text = text.replace(" ,", ",").replace(" .", ".").replace(" )", ")").replace("( ", "(")
        score = mean(item[4] for item in group_sorted)
        if text:
            merged.append((text, score))
    return merged


def compute_ocr_quality(*, lines: list[str], scores: list[float]) -> float:
    if not lines:
        return -1.0
    text = " ".join(lines)
    if not text:
        return -1.0

    chars = len(text)
    ascii_ratio = sum(32 <= ord(ch) < 127 for ch in text) / max(chars, 1)
    alnum_ratio = sum(ch.isalnum() for ch in text) / max(chars, 1)
    operator_ratio = len(re.findall(r"[=+\-*/^()]", text)) / max(chars, 1)
    bad_char_ratio = sum(not (ch.isalnum() or ch.isspace() or ch in ".,:;!?()[]{}+-=*/<>_%'\"") for ch in text) / max(chars, 1)
    vowel_words = 0
    words = re.findall(r"[A-Za-z]{3,}", text)
    for word in words:
        if re.search(r"[aeiouAEIOU]", word):
            vowel_words += 1
    word_ratio = vowel_words / max(len(words), 1) if words else 0.0

    avg_score = mean(scores) if scores else 0.0
    length_bonus = min(chars / 1600.0, 1.0) * 0.12
    formula_bonus = min(operator_ratio * 5.0, 0.12)

    return (
        (avg_score * 0.42)
        + (ascii_ratio * 0.18)
        + (alnum_ratio * 0.16)
        + (word_ratio * 0.12)
        + length_bonus
        + formula_bonus
        - (bad_char_ratio * 0.25)
    )


def inject_ocr_text_into_pages(
    *,
    normalized_document: dict[str, Any],
    page_markdown: dict[int, str],
    page_results: dict[int, PageOcrResult],
) -> int:
    injected = 0
    for page in normalized_document.get("pages", []):
        page_number = page.get("page_number")
        if not isinstance(page_number, int):
            continue
        result = page_results.get(page_number)
        if not result:
            continue

        ocr_text = "\n".join(result.lines).strip()
        if not ocr_text:
            continue

        existing_text = safe_text(page.get("text"))
        if len(existing_text) < 60:
            page["text"] = ocr_text
            injected += 1

        page["ocr_text"] = ocr_text
        page["ocr_formula_lines"] = result.formula_lines
        page["ocr_profile"] = result.selected_profile
        page["ocr_variant"] = result.selected_variant
        page["ocr_quality"] = round(result.quality, 4)
        if result.scores:
            page["ocr_avg_score"] = round(mean(result.scores), 4)

        existing_markdown = page_markdown.get(page_number, "").rstrip()
        ocr_markdown = "\n".join(
            [
                "",
                "## OCR Fallback Text",
                "",
                f"- profile: `{result.selected_profile}`",
                f"- variant: `{result.selected_variant}`",
                f"- quality: `{round(result.quality, 4)}`",
                "",
                "```text",
                *result.lines,
                "```",
                "",
            ]
        )
        page_markdown[page_number] = existing_markdown + "\n" + ocr_markdown
    return injected


def build_written_markdown(
    *,
    source_stem: str,
    page_results: dict[int, PageOcrResult],
    asset_prefix: str,
    include_images: bool = True,
) -> str:
    lines = [f"# {source_stem} written text markdown", ""]
    lines.extend(
        [
            "## OCR Metadata",
            "",
            "- extraction_mode: `high_res_page_ocr_fallback`",
            "",
        ]
    )

    for page_number in sorted(page_results):
        result = page_results[page_number]
        ref = f"{asset_prefix}/{result.image_path.name}" if asset_prefix else ""
        lines.extend([f"## Page {page_number}", ""])
        if include_images:
            lines.extend(
                [
                    "### Page Image",
                    "",
                    f"- image: `{ref}`",
                    f"![page-{page_number}]({ref})",
                    "",
                ]
            )
        lines.extend(
            [
                "### OCR Written Text",
                "",
                f"- selected_profile: `{result.selected_profile}`",
                f"- selected_variant: `{result.selected_variant}`",
                f"- quality: `{round(result.quality, 4)}`",
            ]
        )
        if result.scores:
            lines.append(f"- average_ocr_score: `{round(mean(result.scores), 4)}`")

        if result.lines:
            lines.extend(["", "```text", *result.lines, "```"])
        else:
            lines.extend(["", "_OCR returned empty text for this page._"])

        if result.formula_lines:
            lines.extend(["", "### Formula-Like Lines", "", "```text", *result.formula_lines, "```"])
        lines.append("")

    return "\n".join(lines).strip() + "\n"


def normalize_ocr_line(value: Any) -> str:
    text = safe_text(value)
    if not text:
        return ""
    text = fix_common_mojibake(text)
    text = re.sub(r"[•·▪]", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def is_noise_token(*, text: str, score: float) -> bool:
    lowered = text.lower()
    if "camscanner" in lowered:
        return True
    if "ckah" in lowered:
        return True
    if len(text) <= 1 and score < 0.65:
        return True
    if len(text) <= 2 and score < 0.4 and not re.search(r"[0-9=+\-*/]", text):
        return True
    return False


def dedupe_lines(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def fix_common_mojibake(value: str) -> str:
    if not value:
        return value
    if not re.search(r"[ÃÐÑÂâïåœ]", value):
        return value
    try:
        repaired = value.encode("latin-1", errors="strict").decode("utf-8", errors="strict")
    except Exception:  # noqa: BLE001
        return value
    return repaired


def extract_formula_like_lines(lines: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for line in lines:
        if len(line) > 180:
            continue
        if not re.search(r"[=+\-*/^()]", line):
            continue
        if not re.search(r"[0-9A-Za-z]", line):
            continue
        if line in seen:
            continue
        seen.add(line)
        result.append(line)
    return result[:36]


def build_figure_asset_map(*, blocks: list[dict[str, Any]], asset_dir: Path) -> dict[str, Path]:
    asset_files = sorted(asset_dir.glob("image_*.png"))
    if not asset_files:
        return {}

    mapping: dict[str, Path] = {}
    unresolved: list[str] = []
    used_indexes: set[int] = set()

    for block in blocks:
        if block.get("content_type") != "figure":
            continue
        block_id = safe_text(block.get("block_id"))
        self_ref = safe_text(block.get("layout", {}).get("self_ref"))
        match = re.fullmatch(r"#/pictures/(\d+)", self_ref)
        if not block_id:
            continue
        if not match:
            unresolved.append(block_id)
            continue
        picture_index = int(match.group(1))
        if 0 <= picture_index < len(asset_files):
            mapping[block_id] = asset_files[picture_index]
            used_indexes.add(picture_index)
        else:
            unresolved.append(block_id)

    fallback_assets = [item for idx, item in enumerate(asset_files) if idx not in used_indexes]
    for block_id, asset in zip(unresolved, fallback_assets):
        mapping[block_id] = asset
    return mapping


def first_figure_asset_per_page(
    *,
    pages: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
    figure_asset_map: dict[str, Path],
) -> dict[int, Path]:
    block_map = {safe_text(block.get("block_id")): block for block in blocks}
    result: dict[int, Path] = {}
    for page in pages:
        page_number = page.get("page_number")
        if not isinstance(page_number, int):
            continue
        for block_id in page.get("block_ids", []):
            block = block_map.get(safe_text(block_id))
            if not block or block.get("content_type") != "figure":
                continue
            asset = figure_asset_map.get(safe_text(block.get("block_id")))
            if asset:
                result[page_number] = asset
                break
    return result
