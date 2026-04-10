from fastapi import APIRouter

from app.parsing.contracts import ParseDocumentRequest, ParseDocumentResponse
from app.parsing.service import parse_document_to_markdown

parse_router = APIRouter(prefix="/parse", tags=["parsing"])


@parse_router.get("/")
async def parsing_root() -> dict[str, str]:
    return {
        "status": "ready",
        "message": "Parsing routes are active. POST /parse with source_document_path/source_document_url and topic.",
    }


@parse_router.post("/", response_model=ParseDocumentResponse)
async def parse_document(parse_document_request: ParseDocumentRequest):
    return await parse_document_to_markdown(parse_document_request)
