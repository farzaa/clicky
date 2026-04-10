from fastapi import status
from fastapi.responses import JSONResponse

from app.parsing.contracts import ParseDocumentRequest


async def parse_document_to_markdown_placeholder(
    parse_document_request: ParseDocumentRequest,
) -> JSONResponse:
    return JSONResponse(
        status_code=status.HTTP_501_NOT_IMPLEMENTED,
        content={
            "status": "placeholder",
            "message": "Parsing is not implemented yet. This endpoint is reserved for the PDF-to-markdown pipeline.",
            "source_document_identifier": parse_document_request.source_document_identifier,
            "requested_output_format": parse_document_request.requested_output_format,
        },
    )
