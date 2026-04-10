from datetime import UTC, datetime

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_database_session
from app.models import AuthSession, User
from app.security import hash_session_token


bearer_authentication_scheme = HTTPBearer(auto_error=False)


async def get_current_user(
    database_session: AsyncSession = Depends(get_database_session),
    bearer_credentials: HTTPAuthorizationCredentials | None = Depends(
        bearer_authentication_scheme,
    ),
) -> User:
    if bearer_credentials is None or bearer_credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication is required.",
        )

    session_token_hash = hash_session_token(bearer_credentials.credentials)
    auth_session_query = (
        select(AuthSession)
        .options(selectinload(AuthSession.user))
        .where(AuthSession.session_token_hash == session_token_hash)
    )
    auth_session = (await database_session.execute(auth_session_query)).scalar_one_or_none()

    if auth_session is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid session token.",
        )

    current_datetime = datetime.now(UTC)
    if auth_session.expires_at <= current_datetime:
        await database_session.delete(auth_session)
        await database_session.commit()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Session token has expired.",
        )

    auth_session.last_used_at = current_datetime
    await database_session.commit()

    return auth_session.user
