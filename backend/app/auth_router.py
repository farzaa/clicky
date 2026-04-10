from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_database_session
from app.models import AuthSession, User
from app.security import (
    create_password_hash,
    create_session_expiration_datetime,
    create_session_token,
    hash_session_token,
    normalize_email_address,
    verify_password,
)
from app.workspaces_service import create_workspace_for_user

auth_router = APIRouter(prefix="/auth", tags=["auth"])


class RegisterUserRequest(BaseModel):
    email_address: EmailStr
    password: str = Field(min_length=8, max_length=256)
    display_name: str | None = Field(default=None, max_length=255)


class LoginUserRequest(BaseModel):
    email_address: EmailStr
    password: str = Field(min_length=8, max_length=256)


class AuthenticatedUserResponse(BaseModel):
    id: str
    email_address: EmailStr
    display_name: str | None = None


class AuthSessionResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime
    user: AuthenticatedUserResponse


def build_authenticated_user_response(user: User) -> AuthenticatedUserResponse:
    if user.email_address is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="User email address is missing.",
        )

    return AuthenticatedUserResponse(
        id=str(user.id),
        email_address=user.email_address,
        display_name=user.display_name,
    )


async def create_auth_session_response(
    user: User,
    database_session: AsyncSession,
) -> AuthSessionResponse:
    raw_session_token = create_session_token()
    auth_session = AuthSession(
        user_id=user.id,
        session_token_hash=hash_session_token(raw_session_token),
        expires_at=create_session_expiration_datetime(),
        last_used_at=datetime.now(UTC),
    )
    database_session.add(auth_session)
    await database_session.commit()
    await database_session.refresh(auth_session)

    return AuthSessionResponse(
        access_token=raw_session_token,
        expires_at=auth_session.expires_at,
        user=build_authenticated_user_response(user),
    )


@auth_router.post(
    "/register",
    response_model=AuthSessionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register_user(
    register_user_request: RegisterUserRequest,
    database_session: AsyncSession = Depends(get_database_session),
) -> AuthSessionResponse:
    normalized_email_address = normalize_email_address(
        register_user_request.email_address,
    )
    existing_user_query = select(User).where(User.email_address == normalized_email_address)
    existing_user = (await database_session.execute(existing_user_query)).scalar_one_or_none()

    if existing_user is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A user with that email address already exists.",
        )

    user = User(
        email_address=normalized_email_address,
        display_name=register_user_request.display_name,
        password_hash=create_password_hash(register_user_request.password),
    )
    database_session.add(user)
    await database_session.flush()

    default_workspace_display_name = (
        f"{register_user_request.display_name}'s Workspace"
        if register_user_request.display_name
        else "My Workspace"
    )
    await create_workspace_for_user(
        database_session,
        user=user,
        display_name=default_workspace_display_name,
        workspace_metadata={"created_during_registration": True},
    )

    await database_session.commit()
    await database_session.refresh(user)

    return await create_auth_session_response(user, database_session)


@auth_router.post("/login", response_model=AuthSessionResponse)
async def login_user(
    login_user_request: LoginUserRequest,
    database_session: AsyncSession = Depends(get_database_session),
) -> AuthSessionResponse:
    normalized_email_address = normalize_email_address(login_user_request.email_address)
    user_query = select(User).where(User.email_address == normalized_email_address)
    user = (await database_session.execute(user_query)).scalar_one_or_none()

    if user is None or not verify_password(login_user_request.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email address or password.",
        )

    return await create_auth_session_response(user, database_session)


@auth_router.get("/me", response_model=AuthenticatedUserResponse)
async def get_authenticated_user(
    current_user: User = Depends(get_current_user),
) -> AuthenticatedUserResponse:
    return build_authenticated_user_response(current_user)


@auth_router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout_user(
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> None:
    await database_session.execute(
        delete(AuthSession).where(AuthSession.user_id == current_user.id),
    )
    await database_session.commit()
