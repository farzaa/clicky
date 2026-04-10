from fastapi import APIRouter

from app.parsing.contracts import ParseDocumentRequest, ParseDocumentResponse
from app.parsing.service import parse_document_to_markdown_placeholder

parse_router = APIRouter(prefix="/parse", tags=["parsing"])


@parse_router.get("/")
async def parsing_root() -> dict[str, str]:
    return {
        "status": "placeholder",
        "message": "Parsing routes are scaffolded. Implement the parsing pipeline in app/parsing/service.py.",
    }


@parse_router.post(
    "/",
    response_model=ParseDocumentResponse,
    responses={501: {"model": ParseDocumentResponse}},
)
async def parse_document(parse_document_request: ParseDocumentRequest):
    return await parse_document_to_markdown_placeholder(parse_document_request)
